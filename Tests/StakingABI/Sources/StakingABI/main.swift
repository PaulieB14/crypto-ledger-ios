import Foundation

// Fixtures are real eth_call responses from Arbitrum One, captured 2026-10-26.
var failures = 0
func check(_ name: String, _ got: String, _ expected: String) {
    if got != expected {
        failures += 1
        FileHandle.standardError.write("FAIL \(name): \(got), expected \(expected)\n".data(using: .utf8)!)
    }
}

// Livepeer BondingManager.getDelegator(0xf8b343b3…07bc3)
let delegator = "0x"
    + "00000000000000000000000000000000000000000000000240a9b5bc1254b7a6"   // bondedAmount
    + "0000000000000000000000000000000000000000000000000000000000000000"   // fees
    + "000000000000000000000000a03113bab8d4ebe5695591f60011741233e8b82f"   // delegateAddress
    + "0000000000000000000000000000000000000000000000000000000000000000"
    + "0000000000000000000000000000000000000000000000000000000000001117"   // startRound 4375
    + "0000000000000000000000000000000000000000000000000000000000001120"   // lastClaimRound 4384
    + "0000000000000000000000000000000000000000000000000000000000000011"   // nextUnbondingLockId 17
let w = EthABI.words(delegator)
check("word count", "\(w.count)", "7")
check("bonded wei", "\(EthABI.uint(w[0]))", "41552943256276613030")
check("bonded LPT", "\(EthABI.tokens(EthABI.uint(w[0])))", "41.55294325627661303")
check("orchestrator", EthABI.address(w[2]), "0xa03113bab8d4ebe5695591f60011741233e8b82f")
check("next lock", "\(EthABI.uint(w[6]))", "17")

// Graph: 9,283.95 shares in a pool of 6,310,570.6 GRT / 3,251,480.85 shares
let shares = EthABI.tokens(EthABI.uint("0000000000000000000000000000000000000000000001f748aeae1268fa8c5d"))
let poolTokens = EthABI.uint("000000000000000000000000000000000000000000053850b7ca9300000dcad9")
let poolShares = EthABI.uint("00000000000000000000000000000000000000000002b08721545525d90731e7")
let grt = EthABI.tokens(EthABI.proRata(shares, poolTokens, poolShares))
check("grt ~18018.57", "\(NSDecimalNumber(decimal: grt).doubleValue.rounded())", "18019.0")
check("empty pool", "\(EthABI.proRata(1, 1, 0))", "0")

// Encoding
check("pad address", EthABI.pad(address: "0xA03113bab8d4ebe5695591f60011741233e8b82F"),
      "000000000000000000000000a03113bab8d4ebe5695591f60011741233e8b82f")
check("pad uint", EthABI.pad(uint: 17), String(repeating: "0", count: 62) + "11")
check("zero", "\(EthABI.isZero(String(repeating: "0", count: 64)))", "true")
check("bad length", "\(EthABI.words("0x1234").count)", "0")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("StakingABI: all checks passed")
