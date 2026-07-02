import OSLog
import StoreKit
import SwiftUI

struct TipJarView: View {
    private static let logger = Logger(
        subsystem: "com.shizukusoft.PatronArchiver",
        category: "TipJar"
    )

    private static let productIDs: [String] = [
        "com.shizukusoft.PatronArchiver.tip.small",
        "com.shizukusoft.PatronArchiver.tip.medium",
        "com.shizukusoft.PatronArchiver.tip.large",
    ]

    @State private var showThankYou = false

    var body: some View {
        StoreView(ids: Self.productIDs)
            .productViewStyle(.compact)
            .storeButton(.hidden, for: .cancellation)
            .onInAppPurchaseCompletion { product, result in
                switch result {
                case .success(.success(let verification)):
                    if case .verified(let transaction) = verification {
                        await transaction.finish()
                        showThankYou = true
                        Self.logger.info(
                            "Tip purchased: \(product.id)"
                        )
                    }
                case .success(.pending):
                    Self.logger.debug("Purchase pending")
                case .success(.userCancelled):
                    break
                case .failure(let error):
                    Self.logger.error(
                        "Purchase failed: \(error.localizedDescription)"
                    )
                @unknown default:
                    break
                }
            }
            .alert("Thank You!", isPresented: $showThankYou) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your support is greatly appreciated!")
            }
    }
}
