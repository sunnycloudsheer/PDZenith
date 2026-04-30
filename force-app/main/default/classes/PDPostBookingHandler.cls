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

    @InvocableMethod(
        label='PD Post-Booking Handler'
        description='Runs after SA creation. Assigns PD via sticky/round-robin, creates AssignedResource and Event, stamps Opportunity, Contact and SA.'
        category='Scheduling'
    )
    public static List<PostBookingResult> handlePostBooking(List<PostBookingRequest> requests) {
        List<PostBookingResult> results = new List<PostBookingResult>();

        // ── 1. Bulk-collect IDs ──────────────────────────────────────────
        Set<Id> saIds  = new Set<Id>();
        Set<Id> oppIds = new Set<Id>();
        for (PostBookingRequest req : requests) {
            saIds.add(req.serviceAppointmentId);
            oppIds.add(req.opportunityId);
        }

        // ── 2. Pre-query all shared data OUTSIDE the loop ────────────────
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

        // Pre-query primary contacts for all Opportunities (no SOQL in loop).
        // Primary OCR is used for Event.WhoId (parent attends the meeting).
        Map<Id, Id> oppToContactId = new Map<Id, Id>();
        for (OpportunityContactRole ocr : [
            SELECT OpportunityId, ContactId
            FROM OpportunityContactRole
            WHERE OpportunityId IN :oppIds AND IsPrimary = true
        ]) {
            oppToContactId.put(ocr.OpportunityId, ocr.ContactId);
        }

        // Pre-query STUDENT-role OCRs for all Opportunities. These drive the
        // Student-side Contact writes (Program_Director__c, Stage__c). Per
        // spec the Primary / parent Contact is NEVER written here — the
        // student's Contact is the single source of truth for their lifecycle.
        // First Student wins per Opp in the rare case of duplicates.
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

        // Auto-create a Student-role OCR for any Opp that doesn't already
        // have one. Heuristic: pick the first Contact on the Opp's Account
        // that isn't the Primary OCR's Contact (typically the parent), and
        // attach it as Role='Student'. Best-effort — if the Account has no
        // other Contact, the Opp simply gets no Student-side Contact write
        // and the rest of the booking proceeds normally.
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

        // Pre-query ServiceResources for all sticky PD users (no SOQL in loop)
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

        // ── 3. Process each request, collecting DML for batching ─────────
        List<ServiceAppointment> sasToUpdate       = new List<ServiceAppointment>();
        List<AssignedResource>   arsToInsert       = new List<AssignedResource>();
        List<Event>              eventsToInsert    = new List<Event>();
        List<ServiceResource>    resourcesToUpdate = new List<ServiceResource>();
        List<Opportunity>        oppsToUpdate      = new List<Opportunity>();
        // Student-Contact updates (PD stamp + Stage). Dedupe by Contact Id
        // in case multiple Opps for the same student are processed in one
        // batch — last write wins, matching Salesforce's own DML semantics.
        Map<Id, Contact>         studentContactsById = new Map<Id, Contact>();

        // Track per-request data for result assembly
        List<PostBookingRequest> validRequests = new List<PostBookingRequest>();
        Map<Integer, ServiceResource> indexToPD = new Map<Integer, ServiceResource>();

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

                // Determine sticky resource from pre-queried map
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

                // Query the selected resource (must be per-request since selectPD result varies)
                ServiceResource pd = [
                    SELECT Id, Name, RelatedRecordId, Appointment_Count__c
                    FROM ServiceResource
                    WHERE Id = :selectedResourceId
                    LIMIT 1
                ];

                // ── Build SA update ──
                sa.Meeting_Type__c     = meetingType;
                sa.Subject             = meetingType + ' - Zenith Prep Academy';
                sa.OwnerId            = pd.RelatedRecordId;
                sa.Opportunity__c      = opp.Id;
                sa.Program_Director__c = pd.RelatedRecordId;

                // Find best territory for the PD
                Id pdTerritoryId = findPDTerritory(pd.Id, pd.RelatedRecordId, followUp);
                if (pdTerritoryId != null) {
                    sa.ServiceTerritoryId = pdTerritoryId;
                }
                sasToUpdate.add(sa);

                // ── Build AssignedResource ──
                AssignedResource ar = new AssignedResource();
                ar.ServiceAppointmentId = sa.Id;
                ar.ServiceResourceId    = pd.Id;
                arsToInsert.add(ar);

                // ── Build Event ──
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

                // ── Build ServiceResource count update ──
                pd.Appointment_Count__c = (pd.Appointment_Count__c != null)
                    ? pd.Appointment_Count__c + 1 : 1;
                resourcesToUpdate.add(pd);

                // ── Build Opportunity update (PD stamp + stage) ──
                Opportunity oppUpd = new Opportunity(Id = opp.Id);
                oppUpd.Program_Director__c = pd.RelatedRecordId;
                // First SOM call booked — flip the Opportunity stage to
                // "SOM Scheduled". PD Follow-Up bookings (`followUp=true`)
                // must leave the stage alone — by the time a follow-up
                // happens the opp may already be in "SOM Completed",
                // "Contract Sent", etc., and we don't want to drag it back.
                // Don't downgrade from closed states either, and don't
                // re-stamp if we're already at "SOM Scheduled".
                Boolean isFirstSOMTransition = (!followUp
                    && opp.StageName != 'SOM Scheduled'
                    && opp.StageName != 'Closed Won'
                    && opp.StageName != 'Closed Lost');
                if (isFirstSOMTransition) {
                    oppUpd.StageName = 'SOM Scheduled';
                }
                oppsToUpdate.add(oppUpd);

                // ── Build Student-Contact update (PD stamp + Stage) ──
                // Mirror PD assignment + lifecycle stage onto the
                // Student-role OCR's Contact (NEVER the Primary / parent).
                // Multiple Opps under the same Account each have their own
                // Student OCR, so cross-program writes don't trample each
                // other through a shared parent Contact.
                Id studentContactId = oppToStudentContactId.get(opp.Id);
                if (studentContactId != null) {
                    Contact sc = studentContactsById.containsKey(studentContactId)
                        ? studentContactsById.get(studentContactId)
                        : new Contact(Id = studentContactId);
                    tryPut(sc, 'Program_Director__c', pd.RelatedRecordId);
                    if (isFirstSOMTransition) {
                        // Mirror the "SOM Scheduled" Opp stage onto the
                        // Student's Contact.Stage__c — same value on both sides.
                        tryPut(sc, 'Stage__c', 'SOM Scheduled');
                    }
                    studentContactsById.put(studentContactId, sc);
                }

                // Store for result assembly
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

        // ── 4. Execute all DML in bulk OUTSIDE the loop ──────────────────
        if (!sasToUpdate.isEmpty()) {
            try { update sasToUpdate; }
            catch (Exception ex) { System.debug(LoggingLevel.WARN, 'SA batch update failed: ' + ex.getMessage()); }
        }
        if (!arsToInsert.isEmpty()) {
            try { insert arsToInsert; }
            catch (Exception ex) { System.debug(LoggingLevel.WARN, 'AR batch insert failed: ' + ex.getMessage()); }
        }
        if (!eventsToInsert.isEmpty()) {
            try { insert eventsToInsert; }
            catch (Exception ex) { System.debug(LoggingLevel.WARN, 'Event batch insert failed: ' + ex.getMessage()); }
        }
        if (!resourcesToUpdate.isEmpty()) {
            try { update resourcesToUpdate; }
            catch (Exception ex) { System.debug(LoggingLevel.WARN, 'SR count batch update failed: ' + ex.getMessage()); }
        }
        if (!oppsToUpdate.isEmpty()) {
            try { update oppsToUpdate; }
            catch (Exception ex) { System.debug(LoggingLevel.WARN, 'Opp batch update failed: ' + ex.getMessage()); }
        }
        // Student-Contact batch update — best-effort, never rolls back the
        // booking itself if the Contact write fails (FLS, validation rule,
        // org missing the Stage__c / Program_Director__c fields).
        if (!studentContactsById.isEmpty()) {
            try { update studentContactsById.values(); }
            catch (Exception ex) {
                System.debug(LoggingLevel.WARN,
                    'Student Contact batch update failed: ' + ex.getMessage());
            }
        }

        return results;
    }

    /**
     * Find the best territory for the PD, checking assigned territory first,
     * then falling back to primary territory type.
     */
    private static Id findPDTerritory(Id resourceId, Id pdUserId, Boolean isFollowUp) {
        String durationTag = isFollowUp ? '30' : '60';
        Date today = Date.today();

        // Try assigned territory matching duration
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

        // Fall back to primary territory
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

        // Bulk-check conflicts for ALL valid resources at once
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

    private static void tryPut(SObject rec, String f, Object v) {
        try { rec.put(f, v); } catch (Exception ex) { }
    }

    public class HandlerException extends Exception {}
}
