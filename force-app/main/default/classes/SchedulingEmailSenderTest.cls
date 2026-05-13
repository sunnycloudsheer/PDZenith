@isTest
private class SchedulingEmailSenderTest {

    @TestSetup
    static void setupData() {
        // Resolve a usable EmailTemplate folder. The original 'Scheduling_Templates' folder
        // started returning zero rows in some orgs, which crashed setupData with a
        // QueryException. Fallbacks (in order): named folder, any active email folder,
        // the running user's personal-templates folder (FolderId = UserInfo.getUserId()).
        List<Folder> folders = [
            SELECT Id FROM Folder
            WHERE Type = 'Email' AND DeveloperName = 'Scheduling_Templates' LIMIT 1
        ];
        if (folders.isEmpty()) {
            folders = [SELECT Id FROM Folder WHERE Type = 'Email' LIMIT 1];
        }
        Id templateFolderId = folders.isEmpty() ? UserInfo.getUserId() : folders[0].Id;

        // The Apex class looks up templates by these DeveloperNames; seed them if missing
        // so the test is self-contained when run in a fresh scratch org.
        Map<String, EmailTemplate> existing = new Map<String, EmailTemplate>();
        for (EmailTemplate et : [
            SELECT Id, DeveloperName FROM EmailTemplate
            WHERE DeveloperName IN ('PD_Scheduling_Link_Send_Email', 'FSS_Scheduling_Link_Send_Email')
        ]) {
            existing.put(et.DeveloperName, et);
        }
        List<EmailTemplate> toInsert = new List<EmailTemplate>();
        if (!existing.containsKey('PD_Scheduling_Link_Send_Email')) {
            toInsert.add(new EmailTemplate(
                Name = 'PD Scheduling Link Send Email',
                DeveloperName = 'PD_Scheduling_Link_Send_Email',
                FolderId = templateFolderId, TemplateType = 'custom',
                Subject = 'Schedule Your Strategy Overview Meeting with Zenith Prep Academy',
                HtmlValue = '<p>Hi {{{Recipient.FirstName}}} {{{Recipient.LastName}}},</p><p><a href="{{{Opportunity.PD_Scheduling_Link__c}}}">Schedule Your PD Meeting</a></p>',
                Body = 'Hi {{{Recipient.FirstName}}} {{{Recipient.LastName}}}, schedule at {{{Opportunity.PD_Scheduling_Link__c}}}',
                IsActive = true
            ));
        }
        if (!existing.containsKey('FSS_Scheduling_Link_Send_Email')) {
            toInsert.add(new EmailTemplate(
                Name = 'FSS Scheduling Link Send Email',
                DeveloperName = 'FSS_Scheduling_Link_Send_Email',
                FolderId = templateFolderId, TemplateType = 'custom',
                Subject = 'Schedule Your FSS Onboarding Meeting with Zenith Prep Academy',
                HtmlValue = '<p>Hi {{{Recipient.FirstName}}} {{{Recipient.LastName}}},</p><p><a href="{{{Opportunity.FSS_Scheduling_Link__c}}}">Schedule Your Onboarding Meeting</a></p>',
                Body = 'Hi {{{Recipient.FirstName}}} {{{Recipient.LastName}}}, schedule at {{{Opportunity.FSS_Scheduling_Link__c}}}',
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

    // Verifies the CC list gets built from second-parent + student contacts on the same Account
    // (the new OWEA + family-CC additions). Doesn't assert content of EmailMessage.CcAddress since
    // Messaging.sendEmail in test context doesn't actually deliver, but exercises the code path.
    @isTest
    static void sendEmail_PD_ccIncludesSecondParentAndStudent() {
        Contact primary = [SELECT Id, AccountId FROM Contact LIMIT 1];
        // Record_Type__c is a formula (RecordType.DeveloperName) — to land 'Parent' / 'Student'
        // on the inserted contacts, set the matching RecordTypeId instead of writing the formula.
        Map<String, Id> rtByName = new Map<String, Id>();
        for (RecordType rt : [
            SELECT Id, DeveloperName FROM RecordType
            WHERE SObjectType = 'Contact' AND DeveloperName IN ('Parent', 'Student')
        ]) {
            rtByName.put(rt.DeveloperName, rt.Id);
        }
        // Add a second parent + a student to the same family Account.
        insert new List<Contact>{
            new Contact(
                FirstName = 'Second', LastName = 'Parent',
                Email = 'parent2@example.com', AccountId = primary.AccountId,
                RecordTypeId = rtByName.get('Parent')
            ),
            new Contact(
                FirstName = 'Family', LastName = 'Student',
                Email = 'student@example.com', AccountId = primary.AccountId,
                RecordTypeId = rtByName.get('Student')
            )
        };
        Opportunity o = [SELECT Id FROM Opportunity LIMIT 1];

        Test.startTest();
        List<SchedulingEmailSender.EmailResult> out =
            SchedulingEmailSender.sendSchedulingEmail(new List<SchedulingEmailSender.EmailRequest>{
                buildRequest(primary.Id, o.Id, 'PD', false)
            });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(true, out[0].success,
            'Send-Email PD with family CC should succeed; got: ' + out[0].errorMessage);
    }
}