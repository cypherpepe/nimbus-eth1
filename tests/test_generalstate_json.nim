# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, strformat, strutils, tables, json, ospaths, times, os,
  byteutils, ranges/typedranges, nimcrypto, options,
  eth/[rlp, common, keys], eth/trie/[db, trie_defs], chronicles,
  ./test_helpers, ../nimbus/p2p/executor,
  ../nimbus/[constants, errors, transaction],
  ../nimbus/[vm_state, vm_types, vm_state_transactions, utils],
  ../nimbus/vm/interpreter,
  ../nimbus/db/[db_chain, state_db]

type
  Tester = object
    name: string
    header: BlockHeader
    pre: JsonNode
    tx: Transaction
    expectedHash: string
    expectedLogs: string
    fork: Fork
    debugMode: bool

proc dumpAccount(accountDb: ReadOnlyStateDB, address: EthAddress, name: string): JsonNode =
  result = %{
    "name": %name,
    "address": %($address),
    "nonce": %toHex(accountDb.getNonce(address)),
    "balance": %accountDb.getBalance(address).toHex(),
    "codehash": %($accountDb.getCodeHash(address)),
    "storageRoot": %($accountDb.getStorageRoot(address))
  }

proc dumpDebugData(tester: Tester, vmState: BaseVMState, sender: EthAddress, gasUsed: GasInt) =
  let recipient = tester.tx.getRecipient()
  let miner = tester.header.coinbase
  var accounts = newJObject()

  accounts[$miner] = dumpAccount(vmState.readOnlyStateDB, miner, "miner")
  accounts[$sender] = dumpAccount(vmState.readOnlyStateDB, sender, "sender")
  accounts[$recipient] = dumpAccount(vmState.readOnlyStateDB, recipient, "recipient")

  let accountList = [sender, miner, recipient]
  var i = 0
  for ac, _ in tester.pre:
    let account = ethAddressFromHex(ac)
    if account notin accountList:
      accounts[$account] = dumpAccount(vmState.readOnlyStateDB, account, "pre" & $i)
      inc i

  let debugData = %{
    "gasUsed": %gasUsed,
    "structLogs": vmState.getTracingResult(),
    "accounts": accounts
  }
  writeFile("debug_" & tester.name & ".json", debugData.pretty())

proc testFixtureIndexes(tester: Tester, testStatusIMPL: var TestStatus) =
  var tracerFlags: set[TracerFlags] = if tester.debugMode: {TracerFlags.EnableTracing} else : {}
  var vmState = newBaseVMState(emptyRlpHash, tester.header, newBaseChainDB(newMemoryDb()), tracerFlags)
  vmState.mutateStateDB:
    setupStateDB(tester.pre, db)

  defer:
    let obtainedHash = "0x" & `$`(vmState.readOnlyStateDB.rootHash).toLowerAscii
    check obtainedHash == tester.expectedHash
    let logEntries = vmState.getAndClearLogEntries()
    let actualLogsHash = hashLogEntries(logEntries)
    let expectedLogsHash = toLowerAscii(tester.expectedLogs)
    check(expectedLogsHash == actualLogsHash)

  let sender = tester.tx.getSender()
  if not validateTransaction(vmState, tester.tx, sender):
    vmState.mutateStateDB:
      # pre-EIP158 (e.g., Byzantium) should ensure currentCoinbase exists
      # in later forks, don't create at all
      db.addBalance(tester.header.coinbase, 0.u256)
    return

  var gasUsed: GasInt
  vmState.mutateStateDB:
    gasUsed = tester.tx.processTransaction(sender, vmState, some(tester.fork))
    db.addBalance(tester.header.coinbase, gasUsed.u256 * tester.tx.gasPrice.u256)

  if tester.debugMode:
    tester.dumpDebugData(vmState, sender, gasUsed)

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus, debugMode = false) =
  var tester: Tester
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    tester.name = label
    break

  let fenv = fixture["env"]
  tester.header = BlockHeader(
    coinbase: fenv["currentCoinbase"].getStr.ethAddressFromHex,
    difficulty: fromHex(UInt256, fenv{"currentDifficulty"}.getStr),
    blockNumber: fenv{"currentNumber"}.getHexadecimalInt.u256,
    gasLimit: fenv{"currentGasLimit"}.getHexadecimalInt.GasInt,
    timestamp: fenv{"currentTimestamp"}.getHexadecimalInt.int64.fromUnix,
    stateRoot: emptyRlpHash
    )

  tester.debugMode = debugMode
  let ftrans = fixture["transaction"]
  for fork in supportedForks:
    if fixture["post"].hasKey(forkNames[fork]):
      # echo "[fork: ", forkNames[fork], "]"
      for expectation in fixture["post"][forkNames[fork]]:
        tester.expectedHash = expectation["hash"].getStr
        tester.expectedLogs = expectation["logs"].getStr
        let
          indexes = expectation["indexes"]
          dataIndex = indexes["data"].getInt
          gasIndex = indexes["gas"].getInt
          valueIndex = indexes["value"].getInt
        tester.tx = ftrans.getFixtureTransaction(dataIndex, gasIndex, valueIndex)
        tester.pre = fixture["pre"]
        tester.fork = fork
        testFixtureIndexes(tester, testStatusIMPL)

proc main() =
  if paramCount() == 0:
    # run all test fixtures
    suite "generalstate json tests":
      jsonTest("GeneralStateTests", testFixture)
  else:
    # execute single test in debug mode
    let path = "tests" / "fixtures" / "GeneralStateTests"
    let n = json.parseFile(path / paramStr(1))
    var testStatusIMPL: TestStatus
    testFixture(n, testStatusIMPL, true)

main()
