/// A participant's Yjs `clientID`. The probe always pins this rather than
/// letting Yjs mint a random 53-bit value, because scenario S0.2 turns on
/// whether a server-assigned id makes the tie-break deterministic.
extension type const ClientId(int value) {
  String get label => 'client-$value';
}

extension type const ObjectId(String value) {}
