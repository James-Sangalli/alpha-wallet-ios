// Copyright © 2018 Stormbird PTE. LTD.

import Foundation
import BigInt
import PromiseKit
import AlphaWalletWeb3

///This class temporarily stores the promises used to make function calls. This is so we don't make the same function calls (over network) + arguments combination multiple times concurrently. Once the call completes, we remove it from the cache.
public class CallForAssetAttributeProvider {
    private var inflightPromises: AtomicDictionary<AssetFunctionCall, Promise<AssetInternalValue>> = .init()
    private let sessionsProvider: SessionsProvider

    public init(sessionsProvider: SessionsProvider) {
        self.sessionsProvider = sessionsProvider
    }

    public func getValue(forAttributeId attributeId: AttributeId, functionCall: AssetFunctionCall) -> Subscribable<AssetInternalValue> {
        let subscribable = Subscribable<AssetInternalValue>(nil)
        if let promise = inflightPromises[functionCall] {
            promise.done { result in
                subscribable.send(result)
            }.cauterize()
            return subscribable
        }

        let promise = makeRpcPromise(forAttributeId: attributeId, functionCall: functionCall)
        inflightPromises[functionCall] = promise

        //TODO need to throttle smart contract function calls?
        promise.done { [weak self] result in
            guard let strongSelf = self else { return }
            subscribable.send(result)
            strongSelf.inflightPromises.removeValue(forKey: functionCall)
        }.catch { [weak self] _ in
            guard let strongSelf = self else { return }
            strongSelf.inflightPromises.removeValue(forKey: functionCall)
        }

        return subscribable
    }

    private func makeRpcPromise(forAttributeId attributeId: AttributeId?, functionCall: AssetFunctionCall) -> Promise<AssetInternalValue> {
        guard let function = CallForAssetAttribute(functionName: functionCall.functionName, inputs: functionCall.inputs, output: functionCall.output) else {
            return .init(error: Web3Error(description: "Failed to create CallForAssetAttribute instance for function: \(functionCall.functionName)"))
        }
        guard let session = sessionsProvider.session(for: functionCall.server) else {
            return .init(error: Web3Error(description: "Failed to get session of \(functionCall.server) for function: \(functionCall.functionName)"))
        }
        
        //Fine to store a strong reference to self here because it's still useful to cache the function call result
        return session
            .blockchainProvider
            .callPromise(AssetAttributeMethodCall(functionCall: functionCall, function: function))
    }
}

struct AssetAttributeMethodCall: ContractMethodCall {
    typealias Response = AssetInternalValue

    private let functionCall: AssetFunctionCall
    private let function: CallForAssetAttribute

    let contract: AlphaWallet.Address
    let abi: String
    let name: String
    let parameters: [AnyObject]
    let shouldDelayIfCached: Bool = true

    init(functionCall: AssetFunctionCall, function: CallForAssetAttribute) {
        self.functionCall = functionCall
        self.function = function
        self.contract = functionCall.contract
        self.abi = "[\(function.abi)]"
        self.name = functionCall.functionName
        self.parameters = functionCall.arguments
    }

    func response(from resultObject: Any) throws -> AssetInternalValue {
        guard let dictionary = resultObject as? [String: AnyObject] else {
            throw CastError(actualValue: resultObject, expectedType: [String: AnyObject].self)
        }

        if let value = dictionary["0"] {
            return CallForAssetAttributeProvider.functional.mapValue(of: functionCall.output, for: value)
        } else {
            if case SolidityType.void = functionCall.output.type {
                return .bool(false)
            } else {
                throw Web3Error(description: "nil result from calling: \(function.name)() on contract: \(functionCall.contract.eip55String)")
            }
        }
    }
}

extension CallForAssetAttributeProvider {
    class functional {}
}

extension CallForAssetAttributeProvider.functional {
    static func mapValue(of output: AssetFunctionCall.ReturnType, for value: Any) -> AssetInternalValue {
        switch output.type {
        case .address:
            if let value = value as? AlphaWalletWeb3.EthereumAddress {
                let result = AlphaWallet.Address(address: value)
                return .address(result)
            }
            return .bool(false)
        case .bool:
            let result = value as? Bool ?? false
            return .bool(result)
        case .bytes, .bytes1, .bytes2, .bytes3, .bytes4, .bytes5, .bytes6, .bytes7, .bytes8, .bytes9, .bytes10, .bytes11, .bytes12, .bytes13, .bytes14, .bytes15, .bytes16, .bytes17, .bytes18, .bytes19, .bytes20, .bytes21, .bytes22, .bytes23, .bytes24, .bytes25, .bytes26, .bytes27, .bytes28, .bytes29, .bytes30, .bytes31, .bytes32:
            let result = value as? Data ?? Data()
            return .bytes(result)
        case .string:
            let result = value as? String ?? ""
            return .string(result)
        case .uint, .uint8, .uint16, .uint24, .uint32, .uint40, .uint48, .uint56, .uint64, .uint72, .uint80, .uint88, .uint96, .uint104, .uint112, .uint120, .uint128, .uint136, .uint144, .uint152, .uint160, .uint168, .uint176, .uint184, .uint192, .uint200, .uint208, .uint216, .uint224, .uint232, .uint240, .uint248, .uint256:
            let result = value as? BigUInt ?? BigUInt(0)
            return .uint(result)
        case .int, .int8, .int16, .int24, .int32, .int40, .int48, .int56, .int64, .int72, .int80, .int88, .int96, .int104, .int112, .int120, .int128, .int136, .int144, .int152, .int160, .int168, .int176, .int184, .int192, .int200, .int208, .int216, .int224, .int232, .int240, .int248, .int256:
            let result = value as? BigInt ?? BigInt(0)
            return .int(result)
        case .void:
            //Don't expect to reach here
            return .bool(false)
        }
    }
}
