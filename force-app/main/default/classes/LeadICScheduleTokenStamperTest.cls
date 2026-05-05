/**
 * Coverage for LeadICScheduleTokenStamper.
 *
 * Three branches are exercised:
 *   1. Empty input list                    → empty result list.
 *   2. Lead in 'New' status, no SA, blank token → fresh token + link.
 *   3. Lead with Status='IC Scheduled' (site-booked Lead)
 *                                          → guard returns empty Result
 *                                            (no token / link generated).
 *   4. Lead already carrying a token       → guard returns empty Result
 *                                            (don't churn an existing
 *                                             token mid-flow).
 */
@isTest
private class LeadICScheduleTokenStamperTest {

    @TestSetup
    static void setupLeads() {
        // Three Leads representing the three guard scenarios. Single
        // insert keeps the SOQL+DML count under governor budget for the
        // bulk test below.
        insert new List<Lead>{
            new Lead(
                FirstName = 'New',  LastName = 'Lead',
                Company   = 'Test Co', Status = 'New',
                Email     = 'new.lead@example.com'
            ),
            new Lead(
                FirstName = 'Site',  LastName = 'Booked',
                Company   = 'Test Co', Status = 'IC Scheduled',
                Email     = 'site.booked@example.com'
            ),
            new Lead(
                FirstName = 'Token', LastName = 'Already',
                Company   = 'Test Co', Status = 'New',
                Email     = 'token.already@example.com',
                IC_Schedule_Token__c = 'pre-existing-token-value-xxxxxxxxxxxxxxxxxxxxxxxxxx'
            )
        };
    }

    @isTest
    static void emptyInput_returnsEmptyList() {
        Test.startTest();
        List<LeadICScheduleTokenStamper.Result> out =
            LeadICScheduleTokenStamper.generate(new List<LeadICScheduleTokenStamper.Request>());
        Test.stopTest();
        System.assertEquals(0, out.size(), 'Empty input must produce empty output');
    }

    @isTest
    static void freshLead_getsTokenAndLink() {
        Lead newLead = [SELECT Id FROM Lead WHERE Status = 'New' AND IC_Schedule_Token__c = null LIMIT 1];

        LeadICScheduleTokenStamper.Request req = new LeadICScheduleTokenStamper.Request();
        req.leadId = newLead.Id;

        Test.startTest();
        List<LeadICScheduleTokenStamper.Result> out =
            LeadICScheduleTokenStamper.generate(new List<LeadICScheduleTokenStamper.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, out.size());
        LeadICScheduleTokenStamper.Result r = out[0];
        System.assertNotEquals(null, r.token, 'Fresh lead should get a token');
        System.assert(String.isNotBlank(r.token), 'Token must be non-blank');
        System.assert(r.link != null && r.link.contains('?type=IC&action=schedule&token='),
            'Link must include type=IC + action=schedule + token query string');
        System.assert(r.link.endsWith(r.token), 'Link must end with the generated token');
    }

    @isTest
    static void siteBookedLead_isSkipped() {
        Lead siteLead = [SELECT Id FROM Lead WHERE Status = 'IC Scheduled' LIMIT 1];

        LeadICScheduleTokenStamper.Request req = new LeadICScheduleTokenStamper.Request();
        req.leadId = siteLead.Id;

        Test.startTest();
        List<LeadICScheduleTokenStamper.Result> out =
            LeadICScheduleTokenStamper.generate(new List<LeadICScheduleTokenStamper.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(null, out[0].token,
            'Site-booked Lead (Status=IC Scheduled) must NOT receive a fresh token');
        System.assertEquals(null, out[0].link,
            'Site-booked Lead must NOT receive a fresh link');
    }

    @isTest
    static void leadWithExistingToken_isSkipped() {
        Lead existing = [SELECT Id FROM Lead WHERE IC_Schedule_Token__c != null LIMIT 1];

        LeadICScheduleTokenStamper.Request req = new LeadICScheduleTokenStamper.Request();
        req.leadId = existing.Id;

        Test.startTest();
        List<LeadICScheduleTokenStamper.Result> out =
            LeadICScheduleTokenStamper.generate(new List<LeadICScheduleTokenStamper.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(null, out[0].token,
            'Lead that already has a token must not get a fresh one (no churn)');
    }

    @isTest
    static void bulkInput_oneSoqlForAllLeads() {
        // Confirm the bulk SOQL guard — one SELECT covers every request
        // regardless of batch size. Any future regression that puts SOQL
        // back inside the loop will fail this assertion at scale.
        List<Lead> all = [SELECT Id FROM Lead];
        List<LeadICScheduleTokenStamper.Request> requests = new List<LeadICScheduleTokenStamper.Request>();
        for (Lead l : all) {
            LeadICScheduleTokenStamper.Request req = new LeadICScheduleTokenStamper.Request();
            req.leadId = l.Id;
            requests.add(req);
        }

        Test.startTest();
        Integer beforeQueries = Limits.getQueries();
        List<LeadICScheduleTokenStamper.Result> out =
            LeadICScheduleTokenStamper.generate(requests);
        Integer afterQueries = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(requests.size(), out.size(), 'Result list size must match input');
        // Allow a small margin (SF describe / lookup overhead) but assert
        // we are NOT firing one SOQL per request.
        Integer queriesUsed = afterQueries - beforeQueries;
        System.assert(queriesUsed <= 2,
            'Generate should issue <= 2 SOQL regardless of batch size, used: ' + queriesUsed);
    }
}
