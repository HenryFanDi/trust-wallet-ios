// Copyright DApps Platform Inc. All rights reserved.

import Foundation
import Result
import APIKit
import RealmSwift
import BigInt
import Moya
import TrustCore

enum TokenAction {
    case disable(Bool)
    case updateInfo
}

class TokensDataStore {
    var tokens: Results<TokenObject> {
        return realm.objects(TokenObject.self).filter(NSPredicate(format: "isDisabled == NO"))
            .sorted(byKeyPath: "order", ascending: true)
    }
    // tokens that needs balance and value update
    var tokensBalance: Results<TokenObject> {
        return realm.objects(TokenObject.self).filter(NSPredicate(format: "isDisabled == NO || rawType = \"coin\""))
            .sorted(byKeyPath: "order", ascending: true)
    }
    var nonFungibleTokens: Results<CollectibleTokenCategory> {
        return realm.objects(CollectibleTokenCategory.self).sorted(byKeyPath: "name", ascending: true)
    }
    var tickers: Results<CoinTicker> {
        return realm.objects(CoinTicker.self).filter("tickersKey == %@", CoinTickerKeyMaker.makeCurrencyKey())
    }
    let realm: Realm
    let account: WalletInfo
    var objects: [TokenObject] {
        return realm.objects(TokenObject.self)
            .sorted(byKeyPath: "order", ascending: true)
            .filter { !$0.contract.isEmpty }
    }
    var enabledObject: [TokenObject] {
        return realm.objects(TokenObject.self)
            .sorted(byKeyPath: "order", ascending: true)
            .filter { !$0.isDisabled }
    }

    init(
        realm: Realm,
        account: WalletInfo
    ) {
        self.realm = realm
        self.account = account
        self.removeOldCoins()
        self.addNativeCoins()
    }

    // TODO: Strange situation, it displays old contract addresses, needs to investigate.
    private func removeOldCoins() {
        let oldBMDAddress = "0xD9a2Dc793E1BBce46e2A7E766D7C76FDaF465E48"
        let oldBMVAddress = "0x76eec17d8f2A0faD17C9DF63524799130834d9D2"

        // Realm : Delete `TokenObject`
        var deleteTokens: [TokenObject]? = []
        for token in realm.objects(TokenObject.self) {
            if token.contract.lowercased().contains(oldBMDAddress.lowercased()) ||
               token.contract.lowercased().contains(oldBMVAddress.lowercased()) {
                deleteTokens?.append(token)
            }
        }

        if let deleteTokens = deleteTokens {
            delete(tokens: deleteTokens)
        }

        // Realm : Delete `CoinTicker`
        if let oldBMDCoinTicker = coinTicker(by: EthereumAddress(string: oldBMDAddress)!) {
            try? realm.write {
                realm.delete(oldBMDCoinTicker)
            }
        }

        if let oldBMVCoinTicker = coinTicker(by: EthereumAddress(string: oldBMVAddress)!) {
            try? realm.write {
                realm.delete(oldBMVCoinTicker)
            }
        }
    }

    private func addNativeCoins() {
        if let token = getToken(for: EthereumAddress.zero) {
            try? realm.write {
                realm.delete(token)
            }
        }

        let initialCoins = nativeCoin() + blockmedCoins()
        for token in initialCoins {
            if let _ = getToken(for: token.contractAddress) {
            } else {
                add(tokens: [token])
            }
        }
    }

    func getToken(for address: Address) -> TokenObject? {
        return realm.object(ofType: TokenObject.self, forPrimaryKey: address.description)
    }

    func coinTicker(by contract: Address) -> CoinTicker? {
        return realm.object(ofType: CoinTicker.self, forPrimaryKey: CoinTickerKeyMaker.makePrimaryKey(contract: contract, currencyKey: CoinTickerKeyMaker.makeCurrencyKey()))
    }

    private func nativeCoin() -> [TokenObject] {
        return account.accounts.compactMap { ac in
            guard let coin = ac.coin else {
                return .none
            }
            let viewModel = CoinViewModel(coin: coin)
            let isDisabled: Bool = {
                if !account.mainWallet {
                    return false
                }
                return coin.server.isDisabledByDefault
            }()

            return TokenObject(
                contract: coin.server.priceID.description,
                name: viewModel.name,
                coin: coin,
                type: .coin,
                symbol: viewModel.symbol,
                decimals: coin.server.decimals,
                value: "0",
                isCustom: false,
                isDisabled: isDisabled,
                order: coin.rawValue
            )
        }
    }

    private func blockmedCoins() -> [TokenObject] {
        let bmdTokenContract = isDebug ? "0xb67e1a2BfDb54f5E30dAD2eF938D1468f37d2e6c" : "0x5862A9935Aa62Ca329f679933491057413Ce2943"
        let bmvTokenContract = isDebug ? "0xfb7E652eC2AbD8d0DADeD96F789eC0b20a0eDb41" : "0x60507b69cCF9a30380c0cc7E781E278A355743F7"

        // BMD
        let bmd = TokenObject(
            contract: bmdTokenContract,
            name: "Utility-BlockMed",
            coin: .ethereum,
            type: .ERC20,
            symbol: "BMD",
            decimals: 18,
            value: "0",
            isCustom: true,
            isDisabled: false
        )

        // BMV
        let bmv = TokenObject(
            contract: bmvTokenContract,
            name: "BlockMed Venture",
            coin: .ethereum,
            type: .ERC20,
            symbol: "BMV",
            decimals: 18,
            value: "0",
            isCustom: true,
            isDisabled: false
        )
        return [bmd, bmv]
    }

    static func token(for server: RPCServer) -> TokenObject {
        let coin = server.coin
        let viewModel = CoinViewModel(coin: server.coin)
        return TokenObject(
            contract: server.priceID.description,
            name: viewModel.name,
            coin: coin,
            type: .coin,
            symbol: viewModel.symbol,
            decimals: server.decimals,
            value: "0",
            isCustom: false
        )
    }

    static func getServer(for token: TokenObject) -> RPCServer! {
        return token.coin.server
    }

    func addCustom(token: ERC20Token) {
        let newToken = TokenObject(
            contract: token.contract.description,
            name: token.name,
            coin: token.coin,
            type: .ERC20,
            symbol: token.symbol,
            decimals: token.decimals,
            value: "0",
            isCustom: true
        )
        add(tokens: [newToken])
    }

    func add(tokens: [Object]) {
        try? realm.write {
            if let tokenObjects = tokens as? [TokenObject] {
                let tokenObjectsWithBalance = tokenObjects.map { tokenObject -> TokenObject in
                    tokenObject.balance = self.getBalance(for: tokenObject.address, with: tokenObject.valueBigInt, and: tokenObject.decimals)
                    return tokenObject
                }
                realm.add(tokenObjectsWithBalance, update: true)
            } else {
                realm.add(tokens, update: true)
            }
        }
    }

    func delete(tokens: [Object]) {
        try? realm.write {
            realm.delete(tokens)
        }
    }

    func deleteAll() {
        deleteAllExistingTickers()

        try? realm.write {
            realm.delete(realm.objects(TokenObject.self))
            realm.delete(realm.objects(CollectibleTokenObject.self))
            realm.delete(realm.objects(CollectibleTokenCategory.self))
        }
    }

    //Background update of the Realm model.
    func update(balance: BigInt, for address: Address) {
        if let token = getToken(for: address) {
            let tokenBalance = getBalance(for: token.address, with: balance, and: token.decimals)
            self.realm.writeAsync(obj: token) { (realm, _ ) in
                let update = self.objectToUpdate(for: (address, balance), tokenBalance: tokenBalance)
                realm.create(TokenObject.self, value: update, update: true)
            }
        }
    }

    private func objectToUpdate(for balance: (key: Address, value: BigInt), tokenBalance: Double) -> [String: Any] {
        return [
            "contract": balance.key.description,
            "value": balance.value.description,
            "balance": tokenBalance,
        ]
    }

    func update(tokens: [TokenObject], action: TokenAction) {
        try? realm.write {
            for token in tokens {
                switch action {
                case .disable(let value):
                    token.isDisabled = value
                case .updateInfo:
                    let update: [String: Any] = [
                        "contract": token.address.description,
                        "name": token.name,
                        "symbol": token.symbol,
                        "decimals": token.decimals,
                        "rawType": token.type.rawValue,
                        "rawCoin": token.coin.rawValue,
                    ]
                    realm.create(TokenObject.self, value: update, update: true)
                }
            }
        }
    }

    func saveTickers(tickers: [CoinTicker]) {
        guard !tickers.isEmpty else {
            return
        }
        try? realm.write {
            realm.add(tickers, update: true)
        }
    }

    private var tickerResultsByTickersKey: Results<CoinTicker> {
        return realm.objects(CoinTicker.self).filter("tickersKey == %@", CoinTickerKeyMaker.makeCurrencyKey())
    }

    func deleteAllExistingTickers() {
        try? realm.write {
            realm.delete(tickerResultsByTickersKey)
        }
    }

    func getBalance(for address: Address, with value: BigInt, and decimals: Int) -> Double {
        guard let ticker = coinTicker(by: address),
            let amountInDecimal = EtherNumberFormatter.full.decimal(from: value, decimals: decimals),
            let price = Double(ticker.price) else {
            return TokenObject.DEFAULT_BALANCE
        }
        return amountInDecimal.doubleValue * price
    }

    func clearBalance() {
        try? realm.write {
            let defaultBalanceTokens = tokens.map { token -> TokenObject in
                let tempToken = token
                tempToken.balance = TokenObject.DEFAULT_BALANCE
                return tempToken
            }
            realm.add(defaultBalanceTokens, update: true)
        }
    }
}

extension Coin {
    var server: RPCServer {
        switch self {
        case .bitcoin: return RPCServer.main //TODO
        case .ethereum: return RPCServer.main
        case .ethereumClassic: return RPCServer.classic
        case .gochain: return RPCServer.gochain
        case .callisto: return RPCServer.callisto
        case .poa: return RPCServer.poa
        }
    }
}
