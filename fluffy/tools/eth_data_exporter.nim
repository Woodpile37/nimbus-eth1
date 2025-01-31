# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Tool to download chain history data from local node, and save it to the json
# file or sqlite database.
# In case of json:
# Block data is stored as it gets transmitted over the wire and as defined here:
#  https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#content-keys-and-values
#
# Json file has following format:
# {
#   "hexEncodedBlockHash: {
#     "header": "the rlp encoded block header as a hex string"
#     "body": "the SSZ encoded container of transactions and uncles as a hex string"
#     "receipts: "The SSZ encoded list of the receipts as a hex string"
#     "number": "block number"
#   },
#   ...,
#   ...,
# }
# In case of sqlite:
# Data is saved in a format friendly to history network i.e one table with 3
# columns: contentid, contentkey, content.
# Such format enables queries to quickly find content in range of some node
# which makes it possible to offer content to nodes in bulk.
#
# When using geth as client to download receipts from, be aware that you will
# have to set the number of blocks to maintain the transaction index for to
# unlimited if you want access to all transactions/receipts.
# e.g: `./build/bin/geth --ws --txlookuplimit=0`
#

{.push raises: [Defect].}

import
  std/[json, typetraits, strutils, os],
  confutils,
  stew/[byteutils, io2],
  json_serialization,
  faststreams, chronicles,
  eth/[common, rlp], chronos,
  eth/common/eth_types_json_serialization,
  json_rpc/rpcclient,
  ../seed_db,
  ../../premix/downloader,
  ../network/history/history_content

# Need to be selective due to the `Block` type conflict from downloader
from ../network/history/history_network import encode

proc defaultDataDir*(): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "EthData"
  elif defined(macosx):
    "Library" / "Application Support" / "EthData"
  else:
    ".cache" / "ethData"

  getHomeDir() / dataDir

const
  defaultDataDirDesc = defaultDataDir()
  defaultFileName = "eth-history-data"

type
  StorageMode* = enum
    Json, Db

  ExporterConf* = object
    logLevel* {.
      defaultValue: LogLevel.INFO
      defaultValueDesc: $LogLevel.INFO
      desc: "Sets the log level"
      name: "log-level" .}: LogLevel
    initialBlock* {.
      desc: "Number of first block which should be downloaded"
      defaultValue: 0
      name: "initial-block" .}: uint64
    endBlock* {.
      desc: "Number of last block which should be downloaded"
      defaultValue: 0
      name: "end-block" .}: uint64
    dataDir* {.
      desc: "The directory where generated file will be placed"
      defaultValue: defaultDataDir()
      defaultValueDesc: $defaultDataDirDesc
      name: "data-dir" .}: OutDir
    filename* {.
      desc: "File name (minus extension) where history data will be exported to"
      defaultValue: defaultFileName
      defaultValueDesc: $defaultFileName
      name: "filename" .}: string
    storageMode* {.
      desc: "Storage mode of data export"
      defaultValue: Json
      name: "storage-mode" .}: StorageMode

  DataRecord = object
    header: string
    body: string
    receipts: string
    number: uint64

proc parseCmdArg*(T: type StorageMode, p: TaintedString): T
    {.raises: [Defect, ConfigurationError].} =
  if p == "db":
    return Db
  elif p == "json":
    return Json
  else:
    let msg = "Provided mode: " & p & " is not a valid. Should be `json` or `db`"
    raise newException(ConfigurationError, msg)

proc completeCmdArg*(T: type StorageMode, val: TaintedString): seq[string] =
  return @[]

proc writeBlock(writer: var JsonWriter, blck: Block)
    {.raises: [IOError, Defect].} =
  let
    dataRecord = DataRecord(
      header: rlp.encode(blck.header).to0xHex(),
      body: encode(blck.body).to0xHex(),
      receipts: encode(blck.receipts).to0xHex(),
      number: blck.header.blockNumber.truncate(uint64))

    headerHash = to0xHex(rlpHash(blck.header).data)

  writer.writeField(headerHash, dataRecord)

proc downloadBlock(i: uint64, client: RpcClient): Block =
  let num = u256(i)
  try:
    return requestBlock(num, flags = {DownloadReceipts}, client = some(client))
  except CatchableError as e:
    fatal "Error while requesting Block", error = e.msg, number = i
    quit 1

proc createAndOpenFile(config: ExporterConf): OutputStreamHandle =
  # Creates directory and file specified in config, if file already exists
  # program is aborted with info to user, to avoid losing data

  let fileName: string =
    if not config.filename.endsWith(".json"):
      config.filename & ".json"
    else:
      config.filename

  let filePath = config.dataDir / fileName

  if isFile(filePath):
    fatal "File under provided path already exists and would be overwritten",
      path = filePath
    quit 1

  let res = createPath(distinctBase(config.dataDir))

  if res.isErr():
    fatal "Error occurred while creating directory", error = res.error
    quit 1

  try:
    # this means that each time file be overwritten, but it is ok for such one
    # off toll
    return fileOutput(filePath)
  except IOError as e:
    fatal "Error occurred while opening the file", error = e.msg
    quit 1

proc writeToJson(config: ExporterConf, client: RpcClient) =
  let fh = createAndOpenFile(config)

  try:
    var writer = JsonWriter[DefaultFlavor].init(fh.s, pretty = true)
    writer.beginRecord()
    for i in config.initialBlock..config.endBlock:
      let blck = downloadBlock(i, client)
      writer.writeBlock(blck)
    writer.endRecord()
    info "File successfully written"
  except IOError as e:
    fatal "Error occoured while writing to file", error = e.msg
    quit 1
  finally:
    try:
      fh.close()
    except IOError as e:
      fatal "Error occoured while closing file", error = e.msg
      quit 1

proc writeToDb(config: ExporterConf, client: RpcClient) =
  let db = SeedDb.new(distinctBase(config.dataDir), config.filename)

  defer:
    db.close()

  for i in config.initialBlock..config.endBlock:
    let
      blck = downloadBlock(i, client)
      blockHash = blck.header.blockHash()
      contentKeyType = BlockKey(chainId: 1, blockHash: blockHash)
      headerKey = encode(ContentKey(
        contentType: blockHeader, blockHeaderKey: contentKeyType))
      bodyKey = encode(ContentKey(
        contentType: blockBody, blockBodyKey: contentKeyType))
      receiptsKey = encode(
        ContentKey(contentType: receipts, receiptsKey: contentKeyType))

    db.put(headerKey.toContentId(), headerKey.asSeq(), rlp.encode(blck.header))

    # No need to seed empty lists into database
    if len(blck.body.transactions) > 0 or len(blck.body.uncles) > 0:
      let body = encode(blck.body)
      db.put(bodyKey.toContentId(), bodyKey.asSeq(), body)

    if len(blck.receipts) > 0:
      let receipts = encode(blck.receipts)
      db.put(receiptsKey.toContentId(), receiptsKey.asSeq(), receipts)

  info "Data successfuly written to db"

proc run(config: ExporterConf, client: RpcClient) =
  case config.storageMode
  of Json:
    writeToJson(config, client)
  of Db:
    writeToDb(config, client)

when isMainModule:
  {.pop.}
  let config = ExporterConf.load()
  {.push raises: [Defect].}

  if (config.endBlock < config.initialBlock):
    fatal "Initial block number should be smaller than end block number",
      initialBlock = config.initialBlock,
      endBlock = config.endBlock
    quit 1

  setLogLevel(config.logLevel)

  var client: RpcClient

  try:
    let c = newRpcWebSocketClient()
    # TODO Currently hardcoded to default geth ws address, at some point it may
    # be moved to config
    waitFor c.connect("ws://127.0.0.1:8546")
    client = c
  except CatchableError as e:
    fatal "Error while connecting to data provider", error = e.msg
    quit 1

  try:
    run(config, client)
  finally:
    waitFor client.close()
