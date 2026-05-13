@isTest
private class BookingTokenUtilTest {

    // Verifies a round-trip encrypt -> decrypt returns the same Contact and Opportunity Ids.
    @isTest
    static void encryptThenDecrypt_roundTripsIds() {
        Account a = new Account(Name = 'Token Family');
        insert a;
        Contact c = new Contact(FirstName = 'Tok', LastName = 'En', AccountId = a.Id);
        insert c;
        Opportunity o = new Opportunity(
            Name = 'Token Opp', AccountId = a.Id,
            StageName = 'Qualification', CloseDate = Date.today().addDays(30)
        );
        insert o;

        Test.startTest();
        String token = BookingTokenUtil.encrypt(c.Id, o.Id);
        Map<String, String> decoded = BookingTokenUtil.decrypt(token);
        Test.stopTest();

        System.assertNotEquals(null, token, 'Token must be returned');
        System.assert(String.isNotBlank(token), 'Token must be non-blank');
        System.assertEquals(String.valueOf(c.Id), decoded.get('contactId'), 'contactId must round-trip');
        System.assertEquals(String.valueOf(o.Id), decoded.get('opportunityId'), 'opportunityId must round-trip');
    }

    // Verifies the URL-safe substitutions (+, /, =) are stripped from the token.
    @isTest
    static void encrypt_producesUrlSafeToken() {
        Account a = new Account(Name = 'Url Safe Family');
        insert a;
        Contact c = new Contact(FirstName = 'Url', LastName = 'Safe', AccountId = a.Id);
        insert c;
        Opportunity o = new Opportunity(
            Name = 'UrlSafe Opp', AccountId = a.Id,
            StageName = 'Qualification', CloseDate = Date.today().addDays(30)
        );
        insert o;

        Test.startTest();
        String token = BookingTokenUtil.encrypt(c.Id, o.Id);
        Test.stopTest();

        System.assert(!token.contains('+'), 'Token must not contain +');
        System.assert(!token.contains('/'), 'Token must not contain /');
        System.assert(!token.contains('='), 'Token must not contain =');
    }

    // Verifies decrypt returns an empty map for blank input.
    @isTest
    static void decrypt_blankToken_returnsEmptyMap() {
        Test.startTest();
        Map<String, String> nullResult  = BookingTokenUtil.decrypt(null);
        Map<String, String> emptyResult = BookingTokenUtil.decrypt('');
        Map<String, String> spaceResult = BookingTokenUtil.decrypt('   ');
        Test.stopTest();

        System.assertEquals(0, nullResult.size(),  'null token must yield empty map');
        System.assertEquals(0, emptyResult.size(), 'empty token must yield empty map');
        System.assertEquals(0, spaceResult.size(), 'whitespace token must yield empty map');
    }

    // Verifies two different Id pairs produce different tokens.
    @isTest
    static void encrypt_differentIds_produceDifferentTokens() {
        Account a = new Account(Name = 'Pair Family');
        insert a;
        Contact c1 = new Contact(FirstName = 'Pair', LastName = 'One', AccountId = a.Id);
        Contact c2 = new Contact(FirstName = 'Pair', LastName = 'Two', AccountId = a.Id);
        insert new List<Contact>{ c1, c2 };
        Opportunity o = new Opportunity(
            Name = 'Pair Opp', AccountId = a.Id,
            StageName = 'Qualification', CloseDate = Date.today().addDays(30)
        );
        insert o;

        Test.startTest();
        String tokenA = BookingTokenUtil.encrypt(c1.Id, o.Id);
        String tokenB = BookingTokenUtil.encrypt(c2.Id, o.Id);
        Test.stopTest();

        System.assertNotEquals(tokenA, tokenB, 'Different contactIds must produce different tokens');
    }
}