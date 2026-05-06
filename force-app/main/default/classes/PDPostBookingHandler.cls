public without sharing class PDPostBookingHandler {

    private static final String PD_PROFILE_NAME = 'Program Director';

    public class PostBookingRequest {
        @InvocableVariable(required=true label='Opportunity Id')
        public Id opportunityId;

        @InvocableVariable(required=true label='ServiceAppointment Id')
        public Id serviceAppointmentId;

        @InvocableVariable(label='Is Follow-up Call')
        public Boolean isFollowUp;
    }

    public class PostBookingResult {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String  errorMessage;
        @InvocableVariable public String  pdName;
        @InvocableVariable public Id      pdUserId;
        @InvocableVariable public Id      serviceResourceId;
    }

    // Runs after SA creation: assigns PD, builds AssignedResource and Event, and stamps related records.
    @InvocableMethod(
        label='PD Post-Booking Handler'
        description='Runs after SA creation. Assigns PD via sticky/round-robin, creates AssignedResource and Event, stamps Opportunity, Contact and SA.'
        category='Scheduling'
    )
    public static List<PostBookingResult> handlePostBooking(List<PostBookingRequest> requests) {
        List<PostBookingResult> results = new List<PostBookingResult>();

        Set<Id> saIds  = new Set<Id>();
        Set<Id> oppIds = new Set<Id>();
        for (PostBookingRequest req : requests) {
            saIds.add(req.serviceAppointmentId);
            oppIds.add(req.opportunityId);
        }

        Map<Id, ServiceAppointment> saMap = new Map<Id, ServiceAppointment>([
            SELECT Id, SchedStartTime, SchedEndTime, ServiceTerritoryId,
                   ParentRecordId, ContactId, AccountId, WorkTypeId
            FROM ServiceAppointment
            WHERE Id IN :saIds
        ]);

        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>([
            SELECT Id, Program_Director__c, StageName, AccountId
            FROM Opportunity
            WHERE Id IN :oppIds
        ]);

        Map<Id, Id> oppToContactId = new Map<Id, Id>();
        for (OpportunityContactRole ocr : [
            SELECT OpportunityId, ContactId
            FROM OpportunityContactRole
            WHERE OpportunityId IN :oppIds AND IsPrimary = true
        ]) {
            oppToContactId.put(ocr.OpportunityId, ocr.ContactId);
        }

        Map<Id, Id> oppToStudentContactId = new Map<Id, Id>();
        for (OpportunityContactRole ocr : [
            SELECT OpportunityId, ContactId
            FROM OpportunityContactRole
            WHERE OpportunityId IN :oppIds
              AND Role = 'Student'
              AND ContactId != null
            ORDER BY CreatedDate ASC
        ]) {
            if (!oppToStudentContactId.containsKey(ocr.OpportunityId)) {
                oppToStudentContactId.put(ocr.OpportunityId, ocr.ContactId);
            }
        }

        Set<Id> oppsNeedingStudentOCR = new Set<Id>();
        for (Id oppId : oppIds) {
            if (!oppToStudentContactId.containsKey(oppId)) {
                oppsNeedingStudentOCR.add(oppId);
            }
        }
        if (!oppsNeedingStudentOCR.isEmpty()) {
            Set<Id> accountIds = new Set<Id>();
            for (Id oppId : oppsNeedingStudentOCR) {
                Opportunity opp = oppMap.get(oppId);
                if (opp != null && opp.AccountId != null) {
                    accountIds.add(opp.AccountId);
                }
            }
            Map<Id, List<Contact>> accountToContacts = new Map<Id, List<Contact>>();
            if (!accountIds.isEmpty()) {
                for (Contact c : [
                    SELECT Id, AccountId
                    FROM Contact
                    WHERE AccountId IN :accountIds
                    ORDER BY CreatedDate ASC
                ]) {
                    if (!accountToContacts.containsKey(c.AccountId)) {
                        accountToContacts.put(c.AccountId, new List<Contact>());
                    }
                    accountToContacts.get(c.AccountId).add(c);
                }
            }
            List<OpportunityContactRole> newStudentOCRs = new List<OpportunityContactRole>();
            for (Id oppId : oppsNeedingStudentOCR) {
                Opportunity opp = oppMap.get(oppId);
                if (opp == null || opp.AccountId == null) continue;
                List<Contact> candidates = accountToContacts.get(opp.AccountId);
                if (candidates == null || candidates.isEmpty()) continue;
                Id primaryContactId = oppToContactId.get(oppId);
                for (Contact c : candidates) {
                    if (primaryContactId != null && c.Id == primaryContactId) continue;
                    newStudentOCRs.add(new OpportunityContactRole(
                        OpportunityId = oppId,
                        ContactId     = c.Id,
                        Role          = 'Student'
                    ));
                    break; // first non-Primary Contact wins
                }
            }
            if (!newStudentOCRs.isEmpty()) {
                try {
                    insert newStudentOCRs;
                    for (OpportunityContactRole ocr : newStudentOCRs) {
                        oppToStudentContactId.put(ocr.OpportunityId, ocr.ContactId);
                    }
                } catch (Exception ex) {
                    System.debug(LoggingLevel.WARN,
                        'Auto-create Student OCR failed: ' + ex.getMessage());
                }
            }
        }

        Set<Id> stickyPDUserIds = new Set<Id>();
        for (Opportunity opp : oppMap.values()) {
            if (opp.Program_Director__c != null) {
                stickyPDUserIds.add(opp.Program_Director__c);
            }
        }
        Map<Id, Id> pdUserToResourceId = new Map<Id, Id>();
        if (!stickyPDUserIds.isEmpty()) {
            for (ServiceResource sr : [
                SELECT Id, RelatedRecordId FROM ServiceResource
                WHERE RelatedRecordId IN :stickyPDUserIds AND IsActive = true
            ]) {
                pdUserToResourceId.put(sr.RelatedRecordId, sr.Id);
            }
        }

        List<ServiceAppointment> sasToUpdate       = new List<ServiceAppointment>();
        List<AssignedResource>   arsToInsert       = new List<AssignedResource>();
        List<Event>              eventsToInsert    = new List<Event>();
        List<ServiceResource>    resourcesToUpdate = new List<ServiceResource>();
        Map<Id, Opportunity>     oppsByOppId = new Map<Id, Opportunity>();
        Map<Id, Contact>         studentContactsById = new Map<Id, Contact>();
        Map<Id, ServiceResource> resourceCache = new Map<Id, ServiceResource>();

        for (Integer i = 0; i < requests.size(); i++) {
            PostBookingRequest req = requests[i];
            PostBookingResult res = new PostBookingResult();
            try {
                Boolean followUp    = (req.isFollowUp != null && req.isFollowUp);
                String  meetingType = followUp
                    ? 'Program Director Follow Up'
                    : 'Program Director - 60 Minutes';

                ServiceAppointment sa = saMap.get(req.serviceAppointmentId);
                if (sa == null) {
                    throw new HandlerException('ServiceAppointment not found: ' + req.serviceAppointmentId);
                }

                Opportunity opp = oppMap.get(req.opportunityId);
                if (opp == null) {
                    throw new HandlerException('Opportunity not found: ' + req.opportunityId);
                }

                Id contactId = oppToContactId.get(opp.Id);

                Id stickyResourceId = null;
                if (opp.Program_Director__c != null) {
                    stickyResourceId = pdUserToResourceId.get(opp.Program_Director__c);
                }

                Id selectedResourceId = selectPD(stickyResourceId, sa.SchedStartTime, sa.SchedEndTime);
                if (selectedResourceId == null) {
                    throw new HandlerException(
                        'No available Program Director found for the selected time slot. Please try a different time.'
                    );
                }

                ServiceResource pd = resourceCache.get(selectedResourceId);
                if (pd == null) {
                    List<ServiceResource> srLookup = [
                        SELECT Id, Name, RelatedRecordId, Appointment_Count__c
                        FROM ServiceResource
                        WHERE Id = :selectedResourceId
                        LIMIT 1
                    ];
                    if (srLookup.isEmpty()) {
                        throw new HandlerException(
                            'Selected ServiceResource no longer exists: ' + selectedResourceId);
                    }
                    pd = srLookup[0];
                    resourceCache.put(selectedResourceId, pd);
                }

                sa.Meeting_Type__c     = meetingType;
                sa.Subject             = meetingType + ' - Zenith Prep Academy';
                sa.OwnerId            = pd.RelatedRecordId;
                sa.Opportunity__c      = opp.Id;
                sa.Program_Director__c = pd.RelatedRecordId;

                Id pdTerritoryId = findPDTerritory(pd.Id, pd.RelatedRecordId, followUp);
                if (pdTerritoryId != null) {
                    sa.ServiceTerritoryId = pdTerritoryId;
                }
                sasToUpdate.add(sa);

                AssignedResource ar = new AssignedResource();
                ar.ServiceAppointmentId = sa.Id;
                ar.ServiceResourceId    = pd.Id;
                arsToInsert.add(ar);

                Event evt         = new Event();
                evt.Subject       = meetingType + ' - Zenith Prep Academy';
                evt.StartDateTime = sa.SchedStartTime;
                evt.EndDateTime   = sa.SchedEndTime;
                evt.OwnerId       = pd.RelatedRecordId;
                evt.WhatId        = opp.Id;
                if (contactId != null) {
                    evt.WhoId = contactId;
                }
                evt.ShowAs      = 'Busy';
                evt.Location    = 'Zoom';
                evt.Description = 'Strategy Overview Meeting scheduled.\n\n'
                    + 'Program Director: ' + pd.Name + '\n'
                    + 'Location: Zoom\n\n'
                    + 'Appointment ID: ' + sa.Id + '\n'
                    + 'Opportunity: '    + opp.Id;
                tryPut(evt, 'Service_Appointment__c', sa.Id);
                eventsToInsert.add(evt);

                pd.Appointment_Count__c = (pd.Appointment_Count__c != null)
                    ? pd.Appointment_Count__c + 1 : 1;
                resourcesToUpdate.add(pd);

                Opportunity oppUpd = new Opportunity(Id = opp.Id);
                oppUpd.Program_Director__c = pd.RelatedRecordId;
                Boolean isFirstSOMTransition = (!followUp
                    && opp.StageName != 'SOM Scheduled'
                    && opp.StageName != 'Closed Won'
                    && opp.StageName != 'Closed Lost');
                if (isFirstSOMTransition) {
                    oppUpd.StageName = 'SOM Scheduled';
                }
                oppsByOppId.put(opp.Id, oppUpd);

                Id studentContactId = oppToStudentContactId.get(opp.Id);
                if (studentContactId != null) {
                    Contact sc = studentContactsById.containsKey(studentContactId)
                        ? studentContactsById.get(studentContactId)
                        : new Contact(Id = studentContactId);
                    tryPut(sc, 'Program_Director__c', pd.RelatedRecordId);
                    if (isFirstSOMTransition) {
                        tryPut(sc, 'Stage__c', 'SOM Scheduled');
                    }
                    studentContactsById.put(studentContactId, sc);
                }

                res.success           = true;
                res.pdName            = pd.Name;
                res.pdUserId          = pd.RelatedRecordId;
                res.serviceResourceId = pd.Id;

            } catch (Exception e) {
                res.success      = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }

        if (!sasToUpdate.isEmpty()) {
            logSaveErrors('SA update',  Database.update(sasToUpdate, false));
        }
        if (!arsToInsert.isEmpty()) {
            logSaveErrors('AssignedResource insert', Database.insert(arsToInsert, false));
        }
        if (!eventsToInsert.isEmpty()) {
            logSaveErrors('Event insert', Database.insert(eventsToInsert, false));
        }
        if (!resourcesToUpdate.isEmpty()) {
            logSaveErrors('ServiceResource count update',
                Database.update(resourcesToUpdate, false));
        }
        if (!oppsByOppId.isEmpty()) {
            logSaveErrors('Opportunity update',
                Database.update(oppsByOppId.values(), false));
        }
        if (!studentContactsById.isEmpty()) {
            logSaveErrors('Student Contact update',
                Database.update(studentContactsById.values(), false));
        }

        return results;
    }

    // Logs row-level DML failures at WARN without aborting the rest of the batch.
    private static void logSaveErrors(String label, Database.SaveResult[] saveResults) {
        if (saveResults == null) return;
        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.SaveResult sr = saveResults[i];
            if (sr.isSuccess()) continue;
            for (Database.Error err : sr.getErrors()) {
                System.debug(LoggingLevel.WARN,
                    label + ' partial failure [row ' + i + '] '
                    + err.getStatusCode() + ': ' + err.getMessage()
                    + ' fields=' + err.getFields());
            }
        }
    }

    // Finds the best territory for the PD by duration match, with primary territory fallback.
    private static Id findPDTerritory(Id resourceId, Id pdUserId, Boolean isFollowUp) {
        String durationTag = isFollowUp ? '30' : '60';
        Date today = Date.today();

        for (ServiceTerritoryMember stm : [
            SELECT ServiceTerritoryId FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :resourceId
            AND ServiceTerritory.IsActive = true
            AND ServiceTerritory.Name LIKE :('%' + durationTag + ' Min%')
            AND ServiceTerritory.Assigned_Service_Resource__c = :pdUserId
            AND EffectiveStartDate <= :today
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
            LIMIT 1
        ]) {
            return stm.ServiceTerritoryId;
        }

        for (ServiceTerritoryMember stm : [
            SELECT ServiceTerritoryId FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :resourceId
            AND ServiceTerritory.IsActive = true
            AND TerritoryType = 'P'
            AND EffectiveStartDate <= :today
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
            ORDER BY CreatedDate ASC LIMIT 1
        ]) {
            return stm.ServiceTerritoryId;
        }

        return null;
    }

    // Returns the sticky resource if available, otherwise round-robins by load and conflict.
    private static Id selectPD(Id stickyResourceId, DateTime startDT, DateTime endDT) {
        if (stickyResourceId != null) {
            List<ServiceResource> stickyCheck = [
                SELECT Id, RelatedRecordId FROM ServiceResource
                WHERE Id = :stickyResourceId AND IsActive = true
                LIMIT 1
            ];
            if (!stickyCheck.isEmpty() && stickyCheck[0].RelatedRecordId != null) {
                List<User> pdUser = [
                    SELECT Id FROM User
                    WHERE Id = :stickyCheck[0].RelatedRecordId
                    AND Profile.Name = :PD_PROFILE_NAME
                    AND IsActive = true LIMIT 1
                ];
                if (!pdUser.isEmpty()) {
                    if (isResourceAvailable(stickyResourceId, stickyCheck[0].RelatedRecordId, startDT, endDT)) {
                        return stickyResourceId;
                    }
                }
            }
        }
        return selectByWeightedRoundRobin(startDT, endDT);
    }

    // True when the resource has no SA, Event, or Absence conflict in the time window.
    private static Boolean isResourceAvailable(Id resourceId, Id userId, DateTime startDT, DateTime endDT) {
        Integer saConflicts = [
            SELECT COUNT() FROM AssignedResource
            WHERE ServiceResourceId = :resourceId
            AND ServiceAppointment.SchedStartTime < :endDT
            AND ServiceAppointment.SchedEndTime   > :startDT
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
        ];
        if (saConflicts > 0) return false;

        if (userId != null) {
            Integer evtConflicts = [
                SELECT COUNT() FROM Event
                WHERE OwnerId = :userId
                AND StartDateTime < :endDT
                AND EndDateTime   > :startDT
                AND (ShowAs = NULL OR ShowAs != 'Free')
            ];
            if (evtConflicts > 0) return false;
        }

        Integer absConflicts = [
            SELECT COUNT() FROM ResourceAbsence
            WHERE ResourceId = :resourceId
            AND Start < :endDT
            AND End   > :startDT
        ];
        if (absConflicts > 0) return false;

        return true;
    }

    // Picks the lowest-load available PD ServiceResource for the given time window.
    private static Id selectByWeightedRoundRobin(DateTime startDT, DateTime endDT) {
        Set<Id> pdUserIds = new Set<Id>();
        for (User u : [
            SELECT Id FROM User
            WHERE Profile.Name = :PD_PROFILE_NAME AND IsActive = true
        ]) {
            pdUserIds.add(u.Id);
        }
        if (pdUserIds.isEmpty()) return null;

        List<ServiceResource> pdResources = [
            SELECT Id, Appointment_Count__c, Weight__c, RelatedRecordId
            FROM ServiceResource
            WHERE RelatedRecordId IN :pdUserIds AND IsActive = true
            ORDER BY CreatedDate ASC
        ];
        if (pdResources.isEmpty()) return null;

        Set<Id> allSrIds = new Set<Id>();
        Map<Id, Id> resourceToUser = new Map<Id, Id>();
        for (ServiceResource sr : pdResources) {
            allSrIds.add(sr.Id);
            resourceToUser.put(sr.Id, sr.RelatedRecordId);
        }

        Date today = Date.today();
        Set<Id> resourcesWithTerritory = new Set<Id>();
        for (ServiceTerritoryMember stm : [
            SELECT ServiceResourceId FROM ServiceTerritoryMember
            WHERE ServiceResourceId IN :allSrIds
            AND EffectiveStartDate <= :today
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
            AND ServiceTerritory.IsActive = true
        ]) {
            resourcesWithTerritory.add(stm.ServiceResourceId);
        }

        List<ServiceResource> validResources = new List<ServiceResource>();
        Set<Id> validIds = new Set<Id>();
        for (ServiceResource sr : pdResources) {
            if (resourcesWithTerritory.contains(sr.Id)) {
                validResources.add(sr);
                validIds.add(sr.Id);
            }
        }
        if (validResources.isEmpty()) return null;

        Set<Id> busyResources = new Set<Id>();

        for (AssignedResource arec : [
            SELECT ServiceResourceId FROM AssignedResource
            WHERE ServiceResourceId IN :validIds
            AND ServiceAppointment.SchedStartTime < :endDT
            AND ServiceAppointment.SchedEndTime   > :startDT
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
        ]) {
            busyResources.add(arec.ServiceResourceId);
        }

        Set<Id> validUserIds = new Set<Id>();
        for (Id resId : validIds) {
            Id uid = resourceToUser.get(resId);
            if (uid != null) validUserIds.add(uid);
        }
        if (!validUserIds.isEmpty()) {
            Set<Id> busyUsers = new Set<Id>();
            for (Event ev : [
                SELECT OwnerId FROM Event
                WHERE OwnerId IN :validUserIds
                AND StartDateTime < :endDT
                AND EndDateTime   > :startDT
                AND (ShowAs = NULL OR ShowAs != 'Free')
            ]) {
                busyUsers.add(ev.OwnerId);
            }
            for (Id resId : validIds) {
                Id uid = resourceToUser.get(resId);
                if (uid != null && busyUsers.contains(uid)) {
                    busyResources.add(resId);
                }
            }
        }

        for (ResourceAbsence ra : [
            SELECT ResourceId FROM ResourceAbsence
            WHERE ResourceId IN :validIds
            AND Start < :endDT
            AND End   > :startDT
        ]) {
            busyResources.add(ra.ResourceId);
        }

        Id      bestId   = null;
        Decimal bestLoad = null;
        for (ServiceResource sr : validResources) {
            if (busyResources.contains(sr.Id)) continue;
            Decimal count  = (sr.Appointment_Count__c != null) ? sr.Appointment_Count__c : 0;
            Decimal weight = (sr.Weight__c != null && sr.Weight__c > 0) ? sr.Weight__c : 1.0;
            Decimal load   = count / weight;
            if (bestLoad == null || load < bestLoad) {
                bestLoad = load;
                bestId   = sr.Id;
            }
        }
        return bestId;
    }

    // Safely sets a field on an SObject, swallowing any field-access exception.
    private static void tryPut(SObject rec, String f, Object v) {
        try { rec.put(f, v); } catch (Exception ex) { }
    }

    public class HandlerException extends Exception {}
}