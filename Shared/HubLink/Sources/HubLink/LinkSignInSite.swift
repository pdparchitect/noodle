#if canImport(SwiftUI)
import SwiftUI

/// The site a sign-in form's fields go to, first in the sign-in sheet on the iPhone and the Mac, with a
/// warning when the page is not secure or the form is from another site than the page.
public struct LinkSignInSite: View {
    let form: LinkSignInForm

    public init(_ form: LinkSignInForm) { self.form = form }

    public var body: some View {
        if form.host.isEmpty {
            Label("This form doesn't say which site it's from.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Label(form.host, systemImage: form.secure ? "lock.fill" : "lock.open.fill")
        }
        if !form.secure {
            Label("This page isn't secure.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        if form.crossOrigin {
            Label(form.pageHost.isEmpty ? "This form is from another site." : "This form is from another site than \(form.pageHost).",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
#endif
