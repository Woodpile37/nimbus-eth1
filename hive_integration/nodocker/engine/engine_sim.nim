import
  test_env,
  engine_tests,
  unittest2,
  ../sim_utils

proc main() =
  var stat: SimStat
  let start = getTime()

  for x in engineTestList:
    var t = setupELClient(x.chainFile)
    t.setRealTTD(x.ttd)
    if x.slotsToFinalized != 0:
      t.slotsToFinalized(x.slotsToFinalized)
    if x.slotsToSafe != 0:
      t.slotsToSafe(x.slotsToSafe)
    let status = x.run(t)
    t.stopELClient()
    stat.inc(x.name, status)

  let elpd = getTime() - start
  print(stat, elpd, "engine")
  echo stat

main()
