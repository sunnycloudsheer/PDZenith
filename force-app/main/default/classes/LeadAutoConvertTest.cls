@IsTest
private class LeadAutoConvertTest {

    private static Lead newLead(Map<String, Object> overrides) {
        Lead l = new Lead(
            FirstName = 'Pat',
            LastName  = 'Parent',
            Company   = 'Parent Household',
            Email     = 'pat@example.com',
            Phone     = '5555550000',
            Status    = 'IC Scheduled'
        );
        if (overrides != null) {
            for (String key : overrides.keySet()) {
                l.put(key, overrides.get(key));
            }
        }
        return l;
    }

    private static Lead insertLeadBypassed(Map<String, Object> overrides) {
        LeadAutoConvert.bypassTrigger = true;
        Lead l = newLead(overrides);
        insert l;
        LeadAutoConvert.bypassTrigger = false;
        return l;
    }

    // Verifies a status transition to QUALIFIED converts the Lead and creates the primary Account.
    @IsTest
    static void statusTransition_convertsLeadAndCreatesPrimaryAccount() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'Parent_1_Email__c' => 'pat@example.com',
            'Parent_1_Phone__c' => '5555550000',
            'No_of_Student_Enrolling_Today__c' => '1',
            'Student_Name__c'  => 'Alex Kid',
            'Student_Email__c' => 'alex@example.com'
        });

        Test.startTest();
        l.Status = LeadAutoConvert.QUALIFIED_STATUS;
        update l;
        Test.stopTest();

        Lead refreshed = [SELECT Id, IsConverted, ConvertedAccountId, ConvertedContactId, ConvertedOpportunityId FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, refreshed.IsConverted, 'Lead should be converted.');
        System.assertNotEquals(null, refreshed.ConvertedAccountId);
        System.assertNotEquals(null, refreshed.ConvertedContactId);
        System.assertNotEquals(null, refreshed.ConvertedOpportunityId);
    }

    // Verifies a populated Parent 2 produces a second parent Contact.
    @IsTest
    static void parent2Populated_createsSecondParentContact() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'Parent_2_Name_First_Last__c' => 'Jamie Parent',
            'Parent_2_Email__c' => 'jamie@example.com',
            'Parent_2_Phone__c' => '5555551111',
            'Second_Adult_Type__c' => 'Parent',
            'No_of_Student_Enrolling_Today__c' => '1',
            'Student_Name__c'  => 'Alex Kid',
            'Student_Email__c' => 'alex@example.com'
        });

        Test.startTest();
        l.Status = LeadAutoConvert.QUALIFIED_STATUS;
        update l;
        Test.stopTest();

        Lead converted = [SELECT ConvertedAccountId FROM Lead WHERE Id = :l.Id];
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Email, Phone
            FROM Contact
            WHERE AccountId = :converted.ConvertedAccountId
            ORDER BY LastName, FirstName
        ];
        System.assertEquals(3, contacts.size(), 'Expected primary + Parent 2 + 1 student.');
        Boolean foundParent2 = false;
        for (Contact c : contacts) {
            if (c.Email == 'jamie@example.com') foundParent2 = true;
        }
        System.assertEquals(true, foundParent2, 'Parent 2 contact should have been created.');
    }

    // Verifies three enrolling students produce three student Contacts.
    @IsTest
    static void threeStudents_createsThreeStudentContacts() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'No_of_Student_Enrolling_Today__c' => '3',
            'Student_Name__c'    => 'Alex Kid',
            'Student_Email__c'   => 'alex@example.com',
            'Student_2_Name__c'  => 'Sam Kid',
            'Student_2_Email__c' => 'sam@example.com',
            'Student_3_Name__c'  => 'Jo Kid',
            'Student_3_Email__c' => 'jo@example.com'
        });

        Test.startTest();
        l.Status = LeadAutoConvert.QUALIFIED_STATUS;
        update l;
        Test.stopTest();

        Lead converted = [SELECT ConvertedAccountId FROM Lead WHERE Id = :l.Id];
        List<Contact> contacts = [
            SELECT Id, Email
            FROM Contact
            WHERE AccountId = :converted.ConvertedAccountId
        ];
        System.assertEquals(4, contacts.size(), 'Expected primary + 3 students.');

        Set<String> emails = new Set<String>();
        for (Contact c : contacts) emails.add(c.Email);
        System.assert(emails.contains('alex@example.com'), 'Student 1 missing.');
        System.assert(emails.contains('sam@example.com'),  'Student 2 missing.');
        System.assert(emails.contains('jo@example.com'),   'Student 3 missing.');
    }

    // Verifies the student count caps the conversion to N student Contacts when only N slots are populated.
    @IsTest
    static void studentCountTwo_capsAtTwoEvenIfStudent3Populated() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'No_of_Student_Enrolling_Today__c' => '2',
            'Student_Name__c'    => 'Alex Kid',
            'Student_2_Name__c'  => 'Sam Kid'
        });

        Test.startTest();
        l.Status = LeadAutoConvert.QUALIFIED_STATUS;
        update l;
        Test.stopTest();

        Lead converted = [SELECT ConvertedAccountId FROM Lead WHERE Id = :l.Id];
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :converted.ConvertedAccountId];
        System.assertEquals(3, contacts.size(), 'Expected primary + 2 students.');
    }

    // Verifies a non-qualified status change does not trigger conversion.
    @IsTest
    static void irrelevantStatusChange_doesNotConvert() {
        Lead l = insertLeadBypassed(null);

        Test.startTest();
        l.Status = 'IC Completed – Not Qualified';
        update l;
        Test.stopTest();

        Lead refreshed = [SELECT IsConverted FROM Lead WHERE Id = :l.Id];
        System.assertEquals(false, refreshed.IsConverted, 'Non-qualified status should NOT convert.');
    }

    // Verifies a previously-converted Lead is not re-converted on later status updates.
    @IsTest
    static void alreadyConverted_doesNotReconvert() {
        Lead l = insertLeadBypassed(null);
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(LeadAutoConvert.CONVERTED_STATUS);
        lc.setDoNotCreateOpportunity(true);
        Database.convertLead(lc);

        Lead beforeUpdate = [SELECT IsConverted, ConvertedAccountId FROM Lead WHERE Id = :l.Id];
        Integer accountsBefore = [SELECT COUNT() FROM Account];

        Test.startTest();
        l.Status = LeadAutoConvert.QUALIFIED_STATUS;
        try {
            update l;
        } catch (Exception ignore) { }
        Test.stopTest();

        Integer accountsAfter = [SELECT COUNT() FROM Account];
        System.assertEquals(accountsBefore, accountsAfter,
            'No new Accounts should be created for an already-converted Lead.');
    }

    // Verifies the manual Convert button path also lays down Parent 2 + student Contacts.
    @IsTest
    static void standardConvertButton_alsoCreatesParentAndStudentExtras() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'Parent_2_Name_First_Last__c' => 'Jamie Parent',
            'Parent_2_Email__c' => 'jamie@example.com',
            'No_of_Student_Enrolling_Today__c' => '2',
            'Student_Name__c'    => 'Alex Kid',
            'Student_Email__c'   => 'alex@example.com',
            'Student_2_Name__c'  => 'Sam Kid',
            'Student_2_Email__c' => 'sam@example.com'
        });

        Test.startTest();
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(LeadAutoConvert.CONVERTED_STATUS);
        lc.setDoNotCreateOpportunity(true);
        Database.convertLead(lc);
        Test.stopTest();

        Lead converted = [SELECT ConvertedAccountId FROM Lead WHERE Id = :l.Id];
        List<Contact> contacts = [
            SELECT Id, Email, RecordType.DeveloperName
            FROM Contact
            WHERE AccountId = :converted.ConvertedAccountId
        ];
        System.assertEquals(4, contacts.size(), 'Expected primary + Parent 2 + 2 students.');

        Set<String> studentEmails = new Set<String>();
        for (Contact c : contacts) {
            if (c.RecordType.DeveloperName == 'Student') studentEmails.add(c.Email);
        }
        System.assert(studentEmails.contains('alex@example.com'), 'Student 1 missing.');
        System.assert(studentEmails.contains('sam@example.com'),  'Student 2 missing.');
    }

    // Verifies OpportunityContactRoles are created for every family member across all student Opps.
    @IsTest
    static void statusTransition_createsOpportunityContactRolesForAllFamily() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'Parent_2_Name_First_Last__c' => 'Jamie Parent',
            'Parent_2_Email__c' => 'jamie@example.com',
            'No_of_Student_Enrolling_Today__c' => '2',
            'Student_Name__c'    => 'Alex Kid', 'Student_Email__c'   => 'alex@example.com',
            'Student_2_Name__c'  => 'Sam Kid',  'Student_2_Email__c' => 'sam@example.com'
        });

        Test.startTest();
        l.Status = LeadAutoConvert.QUALIFIED_STATUS;
        update l;
        Test.stopTest();

        Lead converted = [SELECT ConvertedAccountId FROM Lead WHERE Id = :l.Id];
        List<Opportunity> opps = [SELECT Id, StageName FROM Opportunity WHERE AccountId = :converted.ConvertedAccountId];
        System.assertEquals(2, opps.size(), 'Expected one Opportunity per enrolling student.');
        for (Opportunity o : opps) {
            System.assertEquals('SOM Ready', o.StageName, 'Each new Opp should land in the SOM stage.');
        }

        Set<Id> oppIds = (new Map<Id, Opportunity>(opps)).keySet();
        List<OpportunityContactRole> ocrs = [
            SELECT OpportunityId, ContactId, Contact.Email, Role, IsPrimary
            FROM OpportunityContactRole
            WHERE OpportunityId IN :oppIds
        ];
        System.assertEquals(6, ocrs.size(), 'Expected 6 contact roles across both Opps.');

        Map<Id, Integer> parentByOpp  = new Map<Id, Integer>();
        Map<Id, Integer> studentByOpp = new Map<Id, Integer>();
        Map<Id, Integer> primaryByOpp = new Map<Id, Integer>();
        Set<String> studentEmails = new Set<String>();
        for (OpportunityContactRole ocr : ocrs) {
            if (!parentByOpp.containsKey(ocr.OpportunityId)) {
                parentByOpp.put(ocr.OpportunityId, 0);
                studentByOpp.put(ocr.OpportunityId, 0);
                primaryByOpp.put(ocr.OpportunityId, 0);
            }
            if (ocr.Role == 'Parent')   parentByOpp.put(ocr.OpportunityId, parentByOpp.get(ocr.OpportunityId) + 1);
            if (ocr.Role == 'Student') { studentByOpp.put(ocr.OpportunityId, studentByOpp.get(ocr.OpportunityId) + 1); studentEmails.add(ocr.Contact.Email); }
            if (ocr.IsPrimary)          primaryByOpp.put(ocr.OpportunityId, primaryByOpp.get(ocr.OpportunityId) + 1);
        }
        for (Id oppId : oppIds) {
            System.assertEquals(2, parentByOpp.get(oppId),  'Each Opp should have exactly two Parent roles (Parent 1 + Parent 2).');
            System.assertEquals(1, studentByOpp.get(oppId), 'Each Opp should have exactly one Student.');
            System.assertEquals(1, primaryByOpp.get(oppId), 'Each Opp should have exactly one IsPrimary OCR (Parent 1).');
        }
        System.assertEquals(2, studentEmails.size(), 'Expected one distinct student per Opp.');
        System.assert(studentEmails.contains('alex@example.com'), 'Student 1 should be on one Opp.');
        System.assert(studentEmails.contains('sam@example.com'),  'Student 2 should be on the other Opp.');
    }

    // Verifies one Opportunity is created per enrolling student with the correct name pattern.
    @IsTest
    static void statusTransition_createsOneOpportunityPerEnrollingStudent() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'Company' => 'Parent Family',
            'No_of_Student_Enrolling_Today__c' => '3',
            'Student_Name__c'    => 'Alex Kid', 'Student_Email__c'   => 'alex@example.com',
            'Student_2_Name__c'  => 'Sam Kid',  'Student_2_Email__c' => 'sam@example.com',
            'Student_3_Name__c'  => 'Jo Kid',   'Student_3_Email__c' => 'jo@example.com'
        });

        Test.startTest();
        l.Status = LeadAutoConvert.QUALIFIED_STATUS;
        update l;
        Test.stopTest();

        Lead converted = [SELECT ConvertedAccountId FROM Lead WHERE Id = :l.Id];
        Account acc = [SELECT Name FROM Account WHERE Id = :converted.ConvertedAccountId];
        Map<String, String> nameByEmail = new Map<String, String>();
        for (Contact c : [
            SELECT Name, Email FROM Contact
            WHERE AccountId = :converted.ConvertedAccountId AND Email IN ('alex@example.com','sam@example.com','jo@example.com')
        ]) {
            nameByEmail.put(c.Email, c.Name);
        }
        List<Opportunity> opps = [
            SELECT Id, Name FROM Opportunity
            WHERE AccountId = :converted.ConvertedAccountId
        ];
        System.assertEquals(3, opps.size(), 'Expected one Opportunity per enrolling student.');

        Set<String> names = new Set<String>();
        for (Opportunity o : opps) names.add(o.Name);
        for (String email : new List<String>{ 'alex@example.com', 'sam@example.com', 'jo@example.com' }) {
            String expected = nameByEmail.get(email) + ' - ' + acc.Name;
            System.assert(names.contains(expected), 'Missing Opp for ' + email + ' — expected "' + expected + '". Got: ' + names);
        }
    }

    // Verifies the convert path reuses an existing Account/Contact instead of creating duplicates.
    @IsTest
    static void statusTransition_reusesExistingAccountAndContactWhenDuplicatesExist() {
        Account existingAcct = new Account(Name = 'Parent Household');
        insert existingAcct;
        Contact existingContact = new Contact(
            FirstName = 'Pat', LastName = 'Parent',
            Email = 'pat@example.com', AccountId = existingAcct.Id
        );
        insert existingContact;
        Integer accountsBefore = [SELECT COUNT() FROM Account];

        LeadAutoConvert.bypassTrigger = true;
        Lead l = newLead(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'Parent_2_Name_First_Last__c' => 'Jamie Parent',
            'Parent_2_Email__c' => 'jamie@example.com',
            'No_of_Student_Enrolling_Today__c' => '1',
            'Student_Name__c' => 'Alex Kid', 'Student_Email__c' => 'alex@example.com'
        });
        Database.DMLOptions opts = new Database.DMLOptions();
        opts.DuplicateRuleHeader.AllowSave = true;
        Database.insert(l, opts);
        LeadAutoConvert.bypassTrigger = false;

        Test.startTest();
        l.Status = LeadAutoConvert.QUALIFIED_STATUS;
        update l;
        Test.stopTest();

        Integer accountsAfter = [SELECT COUNT() FROM Account];
        System.assertEquals(accountsBefore, accountsAfter, 'No new Account — should reuse existing.');

        Lead converted = [SELECT ConvertedAccountId, ConvertedContactId FROM Lead WHERE Id = :l.Id];
        System.assertEquals(existingAcct.Id,    converted.ConvertedAccountId, 'Should converge on the existing Account.');
        System.assertEquals(existingContact.Id, converted.ConvertedContactId, 'Should converge on the existing Contact.');
    }

    // Verifies the manual Convert button path also creates OpportunityContactRoles.
    @IsTest
    static void standardConvertButton_createsOpportunityContactRoles() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'Parent_2_Name_First_Last__c' => 'Jamie Parent',
            'Parent_2_Email__c' => 'jamie@example.com',
            'No_of_Student_Enrolling_Today__c' => '1',
            'Student_Name__c' => 'Alex Kid', 'Student_Email__c' => 'alex@example.com'
        });

        Test.startTest();
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(LeadAutoConvert.CONVERTED_STATUS);
        lc.setDoNotCreateOpportunity(false);
        Database.convertLead(lc);
        Test.stopTest();

        Lead converted = [SELECT ConvertedOpportunityId FROM Lead WHERE Id = :l.Id];
        System.assertNotEquals(null, converted.ConvertedOpportunityId);

        List<OpportunityContactRole> ocrs = [
            SELECT Role, IsPrimary FROM OpportunityContactRole
            WHERE OpportunityId = :converted.ConvertedOpportunityId
        ];
        System.assertEquals(3, ocrs.size(), 'Expected 3 contact roles.');
        Boolean foundPrimaryParent = false;
        for (OpportunityContactRole ocr : ocrs) {
            if (ocr.Role == 'Parent' && ocr.IsPrimary) foundPrimaryParent = true;
        }
        System.assertEquals(true, foundPrimaryParent, 'Primary contact should have Role=Parent + IsPrimary=true.');
    }

    // Verifies the Opportunity is renamed to "{Student Contact Name} - {Account Name}".
    @IsTest
    static void statusTransition_renamesOpportunityToStudentContactAndAccount() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'Company' => 'Parent Family',
            'No_of_Student_Enrolling_Today__c' => '1',
            'Student_Name__c'  => 'Alex Kid',
            'Student_Email__c' => 'alex@example.com'
        });

        Test.startTest();
        l.Status = LeadAutoConvert.QUALIFIED_STATUS;
        update l;
        Test.stopTest();

        Lead converted = [SELECT ConvertedAccountId, ConvertedOpportunityId FROM Lead WHERE Id = :l.Id];
        System.assertNotEquals(null, converted.ConvertedOpportunityId, 'Opportunity should exist.');

        Account acc = [SELECT Name FROM Account WHERE Id = :converted.ConvertedAccountId];
        Contact studentContact = [
            SELECT Name FROM Contact
            WHERE AccountId = :converted.ConvertedAccountId AND Email = 'alex@example.com'
            LIMIT 1
        ];
        Opportunity opp = [SELECT Name, StageName FROM Opportunity WHERE Id = :converted.ConvertedOpportunityId];
        System.assertEquals(studentContact.Name + ' - ' + acc.Name, opp.Name,
            'Opp name should be "{Student Contact Name} - {Account Name}". Got: ' + opp.Name);
        System.assertEquals('SOM Ready', opp.StageName, 'New Opp should land in the SOM stage.');
    }

    // Verifies pre-generated Parent / Student IDs propagate from Lead to the resulting Contacts.
    @IsTest
    static void statusTransition_mapsParentAndStudentIdsOntoContacts() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'Parent_1_ID__c' => 'P-AAAA1111',
            'Parent_2_Name_First_Last__c' => 'Jamie Parent',
            'Parent_2_Email__c' => 'jamie@example.com',
            'Parent_2_ID__c' => 'P-BBBB2222',
            'No_of_Student_Enrolling_Today__c' => '2',
            'Student_Name__c'    => 'Alex Kid', 'Student_Email__c'   => 'alex@example.com',
            'Student_ID_1__c' => 'S-CCCC3333',
            'Student_2_Name__c'  => 'Sam Kid',  'Student_2_Email__c' => 'sam@example.com',
            'Student_ID_2__c' => 'S-DDDD4444'
        });

        Test.startTest();
        l.Status = LeadAutoConvert.QUALIFIED_STATUS;
        update l;
        Test.stopTest();

        Lead converted = [SELECT ConvertedAccountId, ConvertedContactId FROM Lead WHERE Id = :l.Id];
        Contact primary = [SELECT Parent_ID__c FROM Contact WHERE Id = :converted.ConvertedContactId];
        System.assertEquals('P-AAAA1111', primary.Parent_ID__c, 'Parent 1 ID should land on the primary Contact.');

        Map<String, Contact> byEmail = new Map<String, Contact>();
        for (Contact c : [
            SELECT Email, Parent_ID__c, Student_ID__c
            FROM Contact
            WHERE AccountId = :converted.ConvertedAccountId
        ]) {
            if (c.Email != null) byEmail.put(c.Email, c);
        }
        System.assertEquals('P-BBBB2222', byEmail.get('jamie@example.com').Parent_ID__c, 'Parent 2 ID should land on the Parent 2 Contact.');
        System.assertEquals('S-CCCC3333', byEmail.get('alex@example.com').Student_ID__c, 'Student 1 ID should land on the Student 1 Contact.');
        System.assertEquals('S-DDDD4444', byEmail.get('sam@example.com').Student_ID__c,  'Student 2 ID should land on the Student 2 Contact.');
    }

    // Verifies the invocable entry point runs the same conversion logic.
    @IsTest
    static void invocableEntryPoint_runsTheSameLogic() {
        Lead l = insertLeadBypassed(new Map<String, Object>{
            'Parent_1_Name_First_Last__c' => 'Pat Parent',
            'No_of_Student_Enrolling_Today__c' => '1',
            'Student_Name__c' => 'Alex Kid'
        });

        Test.startTest();
        LeadAutoConvert.convertLeadsInvocable(new List<Id>{ l.Id });
        Test.stopTest();

        Lead refreshed = [SELECT IsConverted FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, refreshed.IsConverted);
    }
}