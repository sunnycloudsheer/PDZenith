@IsTest
private class LeadFamilyControllerTest {

    private static Lead makeLead() {
        return makeLead('3');
    }

    private static Lead makeLead(String numStudents) {
        Lead l = new Lead(
            FirstName = 'Pat',
            LastName  = 'Parent',
            Company   = 'Parent Household',
            Email     = 'pat@example.com',
            Phone     = '5555550000',
            Status    = 'IC Scheduled',
            No_of_Student_Enrolling_Today__c = numStudents
        );
        insert l;
        return l;
    }

    // ─── Students ────────────────────────────────────────────────────
    @IsTest
    static void getStudents_returnsThreeEmptySlots() {
        Lead l = makeLead();

        Test.startTest();
        LeadFamilyController.StudentList out = LeadFamilyController.getStudents(l.Id);
        Test.stopTest();

        System.assertEquals(l.Id, out.leadId);
        System.assertEquals(3, out.students.size());
        for (LeadFamilyController.StudentDTO s : out.students) {
            System.assertEquals(false, s.populated);
        }
    }

    @IsTest
    static void saveStudent_populatesCorrectSlot() {
        Lead l = makeLead();

        Test.startTest();
        LeadFamilyController.saveStudent(l.Id, 1, 'Alex', 'Kid', 'alex@example.com', '10');
        LeadFamilyController.saveStudent(l.Id, 2, 'Sam', 'Kid', 'sam@example.com', '8');
        LeadFamilyController.StudentList out = LeadFamilyController.saveStudent(l.Id, 3, 'Jo', 'Kid', 'jo@example.com', '6');
        Test.stopTest();

        System.assertEquals('Alex', out.students[0].firstName);
        System.assertEquals('Sam Kid', out.students[1].fullName);
        System.assertEquals('Jo Kid', out.students[2].fullName);

        Lead refreshed = [SELECT Student_Name__c, Student_2_Name__c, Student_3_Name__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals('Alex Kid', refreshed.Student_Name__c);
        System.assertEquals('Sam Kid', refreshed.Student_2_Name__c);
        System.assertEquals('Jo Kid', refreshed.Student_3_Name__c);
    }

    @IsTest
    static void saveStudent_rejectsInvalidSlot() {
        Lead l = makeLead();

        Test.startTest();
        Boolean threw = false;
        try {
            LeadFamilyController.saveStudent(l.Id, 4, 'Nope', 'Kid', null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @IsTest
    static void saveStudent_rejectsMissingFields() {
        Lead l = makeLead();

        Test.startTest();
        Boolean badFirst = false;
        Boolean badLast = false;
        Boolean badEmail = false;
        try { LeadFamilyController.saveStudent(l.Id, 1, '', 'K', null, null); } catch (AuraHandledException e) { badFirst = true; }
        try { LeadFamilyController.saveStudent(l.Id, 1, 'A', '  ', null, null); } catch (AuraHandledException e) { badLast = true; }
        try { LeadFamilyController.saveStudent(l.Id, 1, 'A', 'K', 'bad', null); } catch (AuraHandledException e) { badEmail = true; }
        Test.stopTest();

        System.assertEquals(true, badFirst);
        System.assertEquals(true, badLast);
        System.assertEquals(true, badEmail);
    }

    @IsTest
    static void deleteStudent_clearsSlot() {
        Lead l = makeLead();
        LeadFamilyController.saveStudent(l.Id, 2, 'Sam', 'Kid', null, '8');

        Test.startTest();
        LeadFamilyController.StudentList out = LeadFamilyController.deleteStudent(l.Id, 2);
        Test.stopTest();

        System.assertEquals(false, out.students[1].populated);
    }

    @IsTest
    static void saveStudent_blockedWhenFieldBlank() {
        Lead l = makeLead(null);

        Test.startTest();
        Boolean threw = false;
        try {
            LeadFamilyController.saveStudent(l.Id, 1, 'Alex', 'Kid', null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Must reject when "# of Students Enrolling Today" is blank.');
    }

    @IsTest
    static void saveStudent_blockedWhenSlotExceedsCap() {
        Lead l = makeLead('1');

        Test.startTest();
        Boolean threw = false;
        try {
            LeadFamilyController.saveStudent(l.Id, 2, 'Sam', 'Kid', null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Cap is 1, slot 2 must be rejected.');
    }

    @IsTest
    static void saveStudent_allowsEditingExistingSlotEvenIfOverCap() {
        Lead l = makeLead('2');
        LeadFamilyController.saveStudent(l.Id, 1, 'Alex', 'Kid', null, '10');
        LeadFamilyController.saveStudent(l.Id, 2, 'Sam', 'Kid', null, '8');
        // Tighten the cap to 1 AFTER the slots are populated.
        l = [SELECT Id FROM Lead WHERE Id = :l.Id];
        l.No_of_Student_Enrolling_Today__c = '1';
        update l;

        Test.startTest();
        LeadFamilyController.StudentList out = LeadFamilyController.saveStudent(
            l.Id, 2, 'Sam', 'Updated', null, '9'
        );
        Test.stopTest();

        System.assertEquals('Sam Updated', out.students[1].fullName, 'Editing an existing over-cap slot should still work.');
    }

    @IsTest
    static void getStudents_exposesMaxAllowed() {
        Lead l = makeLead('2');

        Test.startTest();
        LeadFamilyController.StudentList out = LeadFamilyController.getStudents(l.Id);
        Test.stopTest();

        System.assertEquals(2, out.maxAllowed);
    }

    // ─── Parents ─────────────────────────────────────────────────────
    @IsTest
    static void getParents_primaryMirrorsLeadIdentity_secondEmptyByDefault() {
        // Parent_1_* is auto-synced from Lead.FirstName / LastName / Email /
        // Phone by LeadParent1SyncTrigger, so a freshly-inserted Lead with
        // those Lead-side fields populated will *always* report Primary as
        // populated. Second (Parent 2) is unset by default.
        Lead l = makeLead();

        Test.startTest();
        LeadFamilyController.ParentList out = LeadFamilyController.getParents(l.Id);
        Test.stopTest();

        System.assertEquals(true, out.primary.populated);
        System.assertEquals('Pat Parent', out.primary.fullName);
        System.assertEquals(false, out.second.populated);
    }

    @IsTest
    static void saveParent_primaryStoresInParent1Fields() {
        Lead l = makeLead();

        Test.startTest();
        LeadFamilyController.ParentList out = LeadFamilyController.saveParent(
            l.Id, 'Primary', null, 'Jamie', 'Parent', 'jamie@example.com', '5555551111'
        );
        Test.stopTest();

        System.assertEquals(true, out.primary.populated);
        System.assertEquals('Parent', out.primary.type);
        System.assertEquals('Jamie Parent', out.primary.fullName);
        Lead refreshed = [SELECT Parent_1_Name_First_Last__c, Parent_1_Email__c, Parent_1_Phone__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals('Jamie Parent', refreshed.Parent_1_Name_First_Last__c);
        System.assertEquals('jamie@example.com', refreshed.Parent_1_Email__c);
    }

    @IsTest
    static void saveParent_secondAsGuardianStoresType() {
        Lead l = makeLead();

        Test.startTest();
        LeadFamilyController.ParentList out = LeadFamilyController.saveParent(
            l.Id, 'Second', 'Guardian', 'Gabby', 'Guard', 'g@example.com', '5555552222'
        );
        Test.stopTest();

        System.assertEquals(true, out.second.populated);
        System.assertEquals('Guardian', out.second.type);
    }

    @IsTest
    static void saveParent_rejectsBadRole() {
        Lead l = makeLead();

        Test.startTest();
        Boolean threw = false;
        try {
            LeadFamilyController.saveParent(l.Id, 'Tertiary', 'Parent', 'X', 'Y', null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @IsTest
    static void saveParent_secondRejectsBadType() {
        Lead l = makeLead();

        Test.startTest();
        Boolean threw = false;
        try {
            LeadFamilyController.saveParent(l.Id, 'Second', 'Cousin', 'X', 'Y', null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @IsTest
    static void deleteParent_clearsRequestedRole() {
        Lead l = makeLead();
        LeadFamilyController.saveParent(l.Id, 'Primary', null, 'Jamie', 'Parent', null, null);
        LeadFamilyController.saveParent(l.Id, 'Second', 'Guardian', 'Gabby', 'Guard', null, null);

        Test.startTest();
        LeadFamilyController.ParentList afterSecondDel = LeadFamilyController.deleteParent(l.Id, 'Second');
        LeadFamilyController.ParentList afterPrimaryDel = LeadFamilyController.deleteParent(l.Id, 'Primary');
        Test.stopTest();

        // Second is fully clearable.
        System.assertEquals(false, afterSecondDel.second.populated);
        System.assertEquals(true, afterSecondDel.primary.populated);

        // Primary can only be partially cleared — Lead.LastName is required
        // and stays, so Parent_1_Name_First_Last__c (synced from LastName)
        // remains non-blank. Email / Phone *do* get cleared.
        Lead refreshed = [SELECT FirstName, Email, Phone, Parent_1_Email__c, Parent_1_Phone__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals(null, refreshed.FirstName);
        System.assertEquals(null, refreshed.Email);
        System.assertEquals(null, refreshed.Phone);
        System.assertEquals(null, refreshed.Parent_1_Email__c);
        System.assertEquals(null, refreshed.Parent_1_Phone__c);
    }

    @IsTest
    static void getParents_nullLeadIdThrows() {
        Test.startTest();
        Boolean threw = false;
        try { LeadFamilyController.getParents(null); } catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }
}
