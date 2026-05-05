public without sharing class BookingTokenUtil {

    // AES-256 key (32 bytes). Move to Custom Metadata or Protected Custom Setting for rotation.
    private static final String KEY_HEX = 'a3f1c9b2e4d6f8071523a4b6c8d0e2f4a1b3c5d7e9f0123456789abcdef01234';

    private static final String SEPARATOR = '|';

    // Encrypts contactId + opportunityId into a URL-safe AES-256 token.
    public static String encrypt(Id contactId, Id opportunityId) {
        String payload = String.valueOf(contactId) + SEPARATOR + String.valueOf(opportunityId);
        Blob key = EncodingUtil.convertFromHex(KEY_HEX);
        Blob encrypted = Crypto.encryptWithManagedIV('AES256', key, Blob.valueOf(payload));
        String b64 = EncodingUtil.base64Encode(encrypted);
        b64 = b64.replace('+', '-').replace('/', '_').replace('=', '');
        return b64;
    }

    // Decrypts a URL-safe token back to contactId and opportunityId.
    public static Map<String, String> decrypt(String token) {
        Map<String, String> result = new Map<String, String>();
        if (String.isBlank(token)) return result;

        String b64 = token.replace('-', '+').replace('_', '/');
        Integer padLen = Math.mod(4 - Math.mod(b64.length(), 4), 4);
        if (padLen < 4) {
            b64 += '='.repeat(padLen);
        }

        Blob key = EncodingUtil.convertFromHex(KEY_HEX);
        Blob decrypted = Crypto.decryptWithManagedIV('AES256', key, EncodingUtil.base64Decode(b64));
        String payload = decrypted.toString();
        List<String> parts = payload.split('\\' + SEPARATOR);
        if (parts.size() >= 2) {
            result.put('contactId', parts[0]);
            result.put('opportunityId', parts[1]);
        }
        return result;
    }
}
