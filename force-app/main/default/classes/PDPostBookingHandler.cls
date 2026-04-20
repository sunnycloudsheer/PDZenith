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
        description='Runs after SA creation. Assigns PD via sticky/round-robin, stamps Opp+Contact+SA, creates AssignedResource and Event.'
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
            FROM ServiceAppointment WHERE Id IN :saIds
        ]);

        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>([
            SELECT Id, Program_Director__c, StageName, AccountId
            FROM Opportunity WHERE Id IN :oppIds
        ]);

        for (PostBookingRequest req : requests) {
            PostBookingResult res = new PostBookingResult();
            try {
                Boolean followUp = (req.isFollowUp != null && req.isFollowUp);
                String meetingType = followUp
                    ? 'Program Director Follow Up'
                    : 'Program Director - 60 Minutes';

                ServiceAppointment sa = saMap.get(req.serviceAppointmentId);
                if (sa == null) throw new HandlerException('ServiceAppointment not found: ' + req.serviceAppointmentId);

                Opportunity opp = oppMap.get(req.opportunityId);
                if (opp == null) throw new HandlerException('Opportunity not found: ' + req.opportunityId);

                Id contactId = null;
                List<OpportunityContactRole> ocrs = [
                    SELECT ContactId FROM OpportunityContactRole
                    WHERE OpportunityId = :opp.Id AND IsPrimary = true LIMIT 1
                ];
                if (!ocrs.isEmpty()) contactId = ocrs[0].ContactId;

                Id stickyResourceId = null;
                if (opp.Program_Director__c != null) {
                    List<ServiceResource> oppSR = [
                        SELECT Id FROM ServiceResource
                        WHERE RelatedRecordId = :opp.Program_Director__c AND IsActive = true LIMIT 1
                    ];
                    if (!oppSR.isEmpty()) stickyResourceId = oppSR[0].Id;
                }

                Id selectedResourceId = selectPD(stickyResourceId, sa.SchedStartTime, sa.SchedEndTime);
                if (selectedResourceId == null) {
                    throw new HandlerException('No available Program Director found for the selected time slot.');
                }

                ServiceResource pd = [
                    SELECT Id, Name, RelatedRecordId, Appointment_Count__c
                    FROM ServiceResource WHERE Id = :selectedResourceId LIMIT 1
                ];
                Id pdUserId = pd.RelatedRecordId;

                // ── STEP 1: Stamp Opportunity + Contact FIRST (before any triggered automation) ──
                Opportunity oppUpd = new Opportunity(Id = opp.Id);
                oppUpd.Program_Director__c = pdUserId;
                oppUpd.StageName = 'SOM Scheduled';
                update oppUpd;

                if (contactId != null) {
                    Contact conUpd = new Contact(Id = contactId);
                    conUpd.Program_Director__c = pdUserId;
                    update conUpd;
                }

                // ── STEP 2: Update ServiceAppointment ──
                sa.Meeting_Type__c = meetingType;
                sa.Subject = meetingType + ' - Zenith Prep Academy';
                sa.OwnerId = pdUserId;
                sa.Opportunity__c = opp.Id;
                sa.Program_Director__c = pdUserId;

                String durationTag = followUp ? '30' : '60';
                Id pdTerritoryId = findPDTerritory(pd.Id, pdUserId, durationTag);
                if (pdTerritoryId != null) sa.ServiceTerritoryId = pdTerritoryId;

                update sa;

                // ── STEP 3: Create AssignedResource ──
                insert new AssignedResource(
                    ServiceAppointmentId = sa.Id,
                    ServiceResourceId = pd.Id
                );

                // ── STEP 4: Increment Appointment Count ──
                pd.Appointment_Count__c = (pd.Appointment_Count__c != null)
                    ? pd.Appointment_Count__c + 1 : 1;
                update pd;

                // ── STEP 5: Create Event (non-critical) ──
                try {
                    Event evt = new Event();
                    evt.Subject = meetingType + ' - Zenith Prep Academy';
                    evt.StartDateTime = sa.SchedStartTime;
                    evt.EndDateTime = sa.SchedEndTime;
                    evt.OwnerId = pdUserId;
                    evt.WhatId = opp.Id;
                    if (contactId != null) evt.WhoId = contactId;
                    evt.ShowAs = 'Busy';
                    evt.Location = 'Zoom';
                    evt.Description = 'Program Director: ' + pd.Name + '\nAppointment: ' + sa.Id;
                    tryPut(evt, 'Service_Appointment__c', sa.Id);
                    insert evt;
                } catch (Exception evtEx) {
                    System.debug(LoggingLevel.WARN, 'Event creation failed: ' + evtEx.getMessage());
                }

                // ── STEP 6: Verify Opp PD persisted (re-stamp if cleared by automation) ──
                Opportunity oppVerify = [SELECT Id, Program_Director__c FROM Opportunity WHERE Id = :opp.Id LIMIT 1];
                if (oppVerify.Program_Director__c != pdUserId) {
                    oppVerify.Program_Director__c = pdUserId;
                    update oppVerify;
                }

                res.success = true;
                res.pdName = pd.Name;
                res.pdUserId = pdUserId;
                res.serviceResourceId = pd.Id;

            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    private static Id findPDTerritory(Id resourceId, Id userId, String durationTag) {
        for (ServiceTerritoryMember stm : [
            SELECT ServiceTerritoryId FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :resourceId
            AND ServiceTerritory.IsActive = true
            AND ServiceTerritory.Name LIKE :('%' + durationTag + ' Min%')
            AND ServiceTerritory.Assigned_Service_Resource__c = :userId
            AND EffectiveStartDate <= :Date.today()
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :Date.today())
            LIMIT 1
        ]) {
            return stm.ServiceTerritoryId;
        }
        for (ServiceTerritoryMember stm : [
            SELECT ServiceTerritoryId FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :resourceId
            AND ServiceTerritory.IsActive = true
            AND TerritoryType = 'P'
            AND EffectiveStartDate <= :Date.today()
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :Date.today())
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
                WHERE Id = :stickyResourceId AND IsActive = true LIMIT 1
            ];
            if (!stickyCheck.isEmpty() && stickyCheck[0].RelatedRecordId != null) {
                List<User> pdUser = [
                    SELECT Id FROM User
                    WHERE Id = :stickyCheck[0].RelatedRecordId
                    AND Profile.Name = :PD_PROFILE_NAME AND IsActive = true LIMIT 1
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
        if ([SELECT COUNT() FROM AssignedResource
             WHERE ServiceResourceId = :resourceId
             AND ServiceAppointment.SchedStartTime < :endDT
             AND ServiceAppointment.SchedEndTime > :startDT
             AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')] > 0)
            return false;

        if (userId != null && [SELECT COUNT() FROM Event
             WHERE OwnerId = :userId
             AND StartDateTime < :endDT AND EndDateTime > :startDT
             AND (ShowAs = NULL OR ShowAs != 'Free')] > 0)
            return false;

        if ([SELECT COUNT() FROM ResourceAbsence
             WHERE ResourceId = :resourceId
             AND Start < :endDT AND End > :startDT] > 0)
            return false;

        return true;
    }

    private static Id selectByWeightedRoundRobin(DateTime startDT, DateTime endDT) {
        Set<Id> pdUserIds = new Set<Id>();
        for (User u : [SELECT Id FROM User WHERE Profile.Name = :PD_PROFILE_NAME AND IsActive = true]) {
            pdUserIds.add(u.Id);
        }
        if (pdUserIds.isEmpty()) return null;

        List<ServiceResource> pdResources = [
            SELECT Id, Appointment_Count__c, Weight__c, RelatedRecordId
            FROM ServiceResource WHERE RelatedRecordId IN :pdUserIds AND IsActive = true
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
        Set<Id> withTerritory = new Set<Id>();
        for (ServiceTerritoryMember stm : [
            SELECT ServiceResourceId FROM ServiceTerritoryMember
            WHERE ServiceResourceId IN :allSrIds
            AND EffectiveStartDate <= :today
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
            AND ServiceTerritory.IsActive = true
        ]) {
            withTerritory.add(stm.ServiceResourceId);
        }

        List<ServiceResource> valid = new List<ServiceResource>();
        Set<Id> validIds = new Set<Id>();
        for (ServiceResource sr : pdResources) {
            if (withTerritory.contains(sr.Id)) {
                valid.add(sr);
                validIds.add(sr.Id);
            }
        }
        if (valid.isEmpty()) return null;

        Set<Id> busy = new Set<Id>();
        for (AssignedResource arec : [
            SELECT ServiceResourceId FROM AssignedResource
            WHERE ServiceResourceId IN :validIds
            AND ServiceAppointment.SchedStartTime < :endDT
            AND ServiceAppointment.SchedEndTime > :startDT
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
        ]) {
            busy.add(arec.ServiceResourceId);
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
                AND StartDateTime < :endDT AND EndDateTime > :startDT
                AND (ShowAs = NULL OR ShowAs != 'Free')
            ]) {
                busyUsers.add(ev.OwnerId);
            }
            for (Id resId : validIds) {
                Id uid = resourceToUser.get(resId);
                if (uid != null && busyUsers.contains(uid)) busy.add(resId);
            }
        }

        for (ResourceAbsence ra : [
            SELECT ResourceId FROM ResourceAbsence
            WHERE ResourceId IN :validIds AND Start < :endDT AND End > :startDT
        ]) {
            busy.add(ra.ResourceId);
        }

        Id bestId = null;
        Decimal bestLoad = null;
        for (ServiceResource sr : valid) {
            if (busy.contains(sr.Id)) continue;
            Decimal count = (sr.Appointment_Count__c != null) ? sr.Appointment_Count__c : 0;
            Decimal weight = (sr.Weight__c != null && sr.Weight__c > 0) ? sr.Weight__c : 1.0;
            Decimal load = count / weight;
            if (bestLoad == null || load < bestLoad) { bestLoad = load; bestId = sr.Id; }
        }
        return bestId;
    }

    private static void tryPut(SObject rec, String f, Object v) {
        try { rec.put(f, v); } catch (Exception ex) { }
    }

    public class HandlerException extends Exception {}
}
