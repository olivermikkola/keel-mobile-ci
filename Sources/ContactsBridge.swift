import Foundation
#if canImport(Contacts)
import Contacts
#endif
#if canImport(KeelHarness)
import KeelHarness
#endif

/// Reads the user's Contacts for `contacts_search`. Read-only: Keel never
/// adds, changes or deletes a contact.
enum ContactsBridge {
    enum BridgeError: LocalizedError {
        case denied
        case unsupported

        var errorDescription: String? {
            switch self {
            case .denied: return "Contacts access is not allowed. Enable it for Keel Mobile in iOS Settings → Privacy & Security → Contacts."
            case .unsupported: return "Contacts are unavailable on this platform."
            }
        }
    }

    /// People whose name (or company) matches `query`, at most `limit`.
    static func search(_ query: String, limit: Int) async throws -> [ContactsTools.Contact] {
        #if canImport(Contacts)
        let store = CNContactStore()
        let granted: Bool
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: granted = true
        case .notDetermined: granted = try await store.requestAccess(for: .contacts)
        default:
            // iOS 18 "limited" access: search the contacts the user shared.
            if #available(iOS 18.0, *), CNContactStore.authorizationStatus(for: .contacts) == .limited { granted = true }
            else { granted = false }
        }
        guard granted else { throw BridgeError.denied }
        return try await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]
            var people = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
            if people.isEmpty {
                // No name matched: try the company name.
                let request = CNContactFetchRequest(keysToFetch: keys)
                let lower = query.lowercased()
                try store.enumerateContacts(with: request) { contact, stop in
                    if contact.organizationName.lowercased().contains(lower) { people.append(contact) }
                    if people.count >= limit { stop.pointee = true }
                }
            }
            return people.prefix(limit).map { contact in
                let name = CNContactFormatter.string(from: contact, style: .fullName)
                    ?? (contact.organizationName.isEmpty ? "(No name)" : contact.organizationName)
                return ContactsTools.Contact(
                    name: name,
                    organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
                    phones: contact.phoneNumbers.map(\.value.stringValue),
                    emails: contact.emailAddresses.map { $0.value as String }
                )
            }
        }.value
        #else
        throw BridgeError.unsupported
        #endif
    }
}
