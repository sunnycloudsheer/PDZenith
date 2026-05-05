@isTest
private class SchedulingEmailSenderTest {

    @TestSetup
    static void setupData() {
        Folder f = [SELECT Id FROM Folder WHERE Type = 'Email' AND DeveloperName = 'Scheduling_Templates' LIMIT 1];

        Map<String, EmailTemplate> existing = new Map<String, EmailTemplate>();
        for (EmailTemplate et : [
            SELECT Id, DeveloperName FROM EmailTemplate
            WHERE DeveloperName IN ('PD_Scheduling_Email', 'FSS_Scheduling_Email')
        ]) {
            existing.put(et.DeveloperName, et);
        }
        List<EmailTemplate> toInsert = new List<EmailTemplate>();
        if (!existing.containsKey('PD_Scheduling_Email')) {
            toInsert.add(new EmailTemplate(
                Name = 'PD Scheduling Email',
                DeveloperName = 'PD_Scheduling_Email',
                FolderId = f.Id, TemplateType = 'custom',
                Subject = 'Schedule with your PD',
                HtmlValue = '<p>Hi {!Contact.FirstName}, schedule at [[SCHEDULING_LINK]]</p>',
                Body = 'Hi {!Contact.FirstName}, schedule at [[SCHEDULING_LINK]]',
                IsActive = true
            ));
        }
        if (!existing.containsKey('FSS_Scheduling_Email')) {
            toInsert.add(new EmailTemplate(
                Name = 'FSS Scheduling Email',
                DeveloperName = 'FSS_Scheduling_Email',
                FolderId = f.Id, TemplateType = 'custom',
                Subject = 'Onboarding with FSS',
                HtmlValue = '<p>Hi {!Contact.FirstName}, [[SCHEDULING_LINK]]</p>',
                Body = 'Hi {!Contact.FirstName}, [[SCHEDULING_LINK]]',
                IsActive = true
            ));
        }
        if (!toInsert.isEmpty()) insert toInsert;

        Account a = new Account(Name = 'Test Family');
        insert a;

        Contact c = new Contact(
            FirstName = 'Test', LastName = 'Parent',
            Email = 'parent@example.com', AccountId = a.Id
        );
        insert c;

        Opportunity opp = new Opportunity(
            Name = 'Test Family Opp',
            AccountId = a.Id,
            StageName = 'SOM Ready',
            CloseDate = Date.today().addDays(60)
        );
        insert opp;

        insert new OpportunityContactRole(
            OpportunityId = opp.Id, ContactId = c.Id,
            IsPrimary = true, Role = 'Decision Maker'
        );
    }

    private static SchedulingEmailSender.EmailRequest buildRequest(
            Id contactId, Id opportunityId, String emailType, Boolean skipEmail) {
        SchedulingEmailSender.EmailRequest req = new SchedulingEmailSender.EmailRequest();
        req.contactId = contactId;
        req.opportunityId = opportunityId;
        req.emailType = emailType;
        req.skipEmail = skipEmail;
        return req;
    }

    // Verifies generate-only PD stamps the link without sending an email.
    @isTest
    static void generateOnly_PD_stampsLinkAndSkipsEmail() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        Opportunity o = [SELECT Id, StageName FROM Opportunity LIMIT 1];

        Test.startTest();
        Integer emailsBefore = Limits.getEmailInvocations();
        List<SchedulingEmailSender.EmailResult> out =
            SchedulingEmailSender.sendSchedulingEmail(new List<SchedulingEmailSender.EmailRequest>{
                buildRequest(c.Id, o.Id, 'PD', true)
            });
        Integer emailsAfter = Limits.getEmailInvocations();
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(true, out[0].success, 'Generate-only PD should succeed');
        System.assertEquals(emailsBefore, emailsAfter,
            'Generate-only mode must NOT consume an email send');

        Opportunity reread = [SELECT PD_Scheduling_Link__c, StageName FROM Opportunity WHERE Id = :o.Id];
        System.assertNotEquals(null, reread.PD_Scheduling_Link__c,
            'PD link field must be populated after generate-only');
        System.assert(reread.PD_Scheduling_Link__c.contains('?type=PD&token='),
            'PD link must contain expected query string');
    }

    // Verifies generate-only FSS stamps the FSS link and leaves the PD link untouched.
    @isTest
    static void generateOnly_FSS_stampsFSSLink() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];

        Test.startTest();
        List<SchedulingEmailSender.EmailResult> out =
            SchedulingEmailSender.sendSchedulingEmail(new List<SchedulingEmailSender.EmailRequest>{
                buildRequest(c.Id, o.Id, 'FSS', true)
            });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(true, out[0].success);

        Opportunity reread = [SELECT FSS_Scheduling_Link__c, PD_Scheduling_Link__c FROM Opportunity WHERE Id = :o.Id];
        System.assertNotEquals(null, reread.FSS_Scheduling_Link__c,
            'FSS link field must be populated after generate-only FSS');
        System.assertEquals(null, reread.PD_Scheduling_Link__c,
            'PD link must remain null when only FSS link is generated');
    }

    // Verifies the Send-Email PD path stamps a fresh link and flips StageName to "SOM Link Sent".
    @isTest
    static void sendEmail_PD_freshLink_stampsLinkAndStage() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];

        Test.startTest();
        List<SchedulingEmailSender.EmailResult> out =
            SchedulingEmailSender.sendSchedulingEmail(new List<SchedulingEmailSender.EmailRequest>{
                buildRequest(c.Id, o.Id, 'PD', false)
            });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(true, out[0].success,
            'Send-Email PD should succeed; got: ' + out[0].errorMessage);

        Opportunity reread = [SELECT PD_Scheduling_Link__c, StageName FROM Opportunity WHERE Id = :o.Id];
        System.assertNotEquals(null, reread.PD_Scheduling_Link__c,
            'Send-Email PD must stamp the link field');
        System.assertEquals('SOM Link Sent', reread.StageName,
            'Send-Email PD must flip StageName to "SOM Link Sent" from "SOM Ready"');
    }

    // Verifies the Send-Email PD path reuses an existing link and does not mint a new token.
    @isTest
    static void sendEmail_PD_reusesExistingLink() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];

        String preExistingLink = 'https://existing.example.com/booking?type=PD&token=PRE_EXISTING';
        update new Opportunity(Id = o.Id, PD_Scheduling_Link__c = preExistingLink);

        Test.startTest();
        List<SchedulingEmailSender.EmailResult> out =
            SchedulingEmailSender.sendSchedulingEmail(new List<SchedulingEmailSender.EmailRequest>{
                buildRequest(c.Id, o.Id, 'PD', false)
            });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(true, out[0].success);

        Opportunity reread = [SELECT PD_Scheduling_Link__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(preExistingLink, reread.PD_Scheduling_Link__c,
            'Send-Email path must reuse the existing PD link, not mint a new one');
    }

    // Verifies an unknown emailType returns success=false.
    @isTest
    static void unknownEmailType_returnsError() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];

        Test.startTest();
        List<SchedulingEmailSender.EmailResult> out =
            SchedulingEmailSender.sendSchedulingEmail(new List<SchedulingEmailSender.EmailRequest>{
                buildRequest(c.Id, o.Id, 'XYZ', false)
            });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(false, out[0].success,
            'Unknown emailType must return success=false');
    }

    // Verifies a bulk batch with the same Opp twice does not raise DUPLICATE_VALUE on Opportunity update.
    @isTest
    static void bulk_sameOppTwice_noDuplicateValueError() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];

        Test.startTest();
        List<SchedulingEmailSender.EmailResult> out =
            SchedulingEmailSender.sendSchedulingEmail(new List<SchedulingEmailSender.EmailRequest>{
                buildRequest(c.Id, o.Id, 'PD',  true),
                buildRequest(c.Id, o.Id, 'FSS', true)
            });
        Test.stopTest();

        System.assertEquals(2, out.size());
        System.assertEquals(true, out[0].success, 'PD generate failed: ' + out[0].errorMessage);
        System.assertEquals(true, out[1].success, 'FSS generate failed: ' + out[1].errorMessage);

        Opportunity reread = [SELECT PD_Scheduling_Link__c, FSS_Scheduling_Link__c FROM Opportunity WHERE Id = :o.Id];
        System.assertNotEquals(null, reread.PD_Scheduling_Link__c, 'PD link should be set');
        System.assertNotEquals(null, reread.FSS_Scheduling_Link__c, 'FSS link should be set');
    }

    // Verifies an empty input list returns an empty result list.
    @isTest
    static void emptyInput_returnsEmptyList() {
        Test.startTest();
        List<SchedulingEmailSender.EmailResult> out =
            SchedulingEmailSender.sendSchedulingEmail(new List<SchedulingEmailSender.EmailRequest>());
        Test.stopTest();
        System.assertEquals(0, out.size());
    }
}
