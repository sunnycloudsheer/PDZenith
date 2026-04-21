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
            SELECT Id, Program_Director__c, Family_Success_Specialist__c, StageName, AccountId
            FROM Opportunity
            WHERE Id IN :oppIds
        ]);

        for (PostBookingRequest req : requests) {
            PostBookingResult res = new PostBookingResult();
            Id resolvedContactId = null;
            Id resolvedPdUserId  = null;
            Id resolvedFssUserId = null;

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

                List<OpportunityContactRole> ocrs = [
                    SELECT ContactId
                    FROM OpportunityContactRole
                    WHERE OpportunityId = :opp.Id AND IsPrimary = true
                    LIMIT 1
                ];
                if (!ocrs.isEmpty()) {
                    resolvedContactId = ocrs[0].ContactId;
                }

                // Resolve the primary Contact's Account. This Account becomes the SA parent
                // (SA.ParentRecordId) — never the Opportunity. Order of preference:
                //   1. Contact.AccountId from the resolved primary contact
                //   2. Opportunity.AccountId (fallback when the Opportunity has no primary OCR)
                Id resolvedAccountId = null;
                if (resolvedContactId != null) {
                    List<Contact> cons = [SELECT AccountId, Family_Success_Specialist__c FROM Contact WHERE Id = :resolvedContactId LIMIT 1];
                    if (!cons.isEmpty() && cons[0].AccountId != null) {
                        resolvedAccountId = cons[0].AccountId;
                    }
                    if (!cons.isEmpty() && cons[0].Family_Success_Specialist__c != null) {
                        resolvedFssUserId = cons[0].Family_Success_Specialist__c;
                    }
                }
                // Fallback: read FSS from Opportunity if Contact didn't have one
                if (resolvedFssUserId == null && opp.Family_Success_Specialist__c != null) {
                    resolvedFssUserId = opp.Family_Success_Specialist__c;
                }
                if (resolvedAccountId == null && opp.AccountId != null) {
                    resolvedAccountId = opp.AccountId;
                }

                Id stickyResourceId = null;
                if (opp.Program_Director__c != null) {
                    List<ServiceResource> oppSR = [
                        SELECT Id FROM ServiceResource
                        WHERE RelatedRecordId = :opp.Program_Director__c AND IsActive = true LIMIT 1
                    ];
                    if (!oppSR.isEmpty()) {
                        stickyResourceId = oppSR[0].Id;
                    }
                }

                Id selectedResourceId = selectPD(stickyResourceId, sa.SchedStartTime, sa.SchedEndTime);
                if (selectedResourceId == null) {
                    throw new HandlerException(
                        'No available Program Director found for the selected time slot. Please try a different time.'
                    );
                }

                ServiceResource pd = [
                    SELECT Id, Name, RelatedRecordId, Appointment_Count__c
                    FROM ServiceResource
                    WHERE Id = :selectedResourceId
                    LIMIT 1
                ];
                resolvedPdUserId = pd.RelatedRecordId;

                sa.Meeting_Type__c = meetingType;
                sa.Subject         = meetingType + ' - Zenith Prep Academy';
                sa.OwnerId         = pd.RelatedRecordId;
                sa.Opportunity__c  = opp.Id;
                sa.Program_Director__c = pd.RelatedRecordId;
                if (resolvedFssUserId != null) {
                    sa.Family_Success_Specialist__c = resolvedFssUserId;
                }
                // ParentRecordId MUST be the primary Contact's Account — never the Opportunity.
                // Only overwrite if we actually resolved an Account; otherwise leave whatever the
                // Flow originally set so we don't accidentally blank it out.
                if (resolvedAccountId != null) {
                    sa.ParentRecordId = resolvedAccountId;
                }
                if (resolvedContactId != null) {
                    sa.ContactId = resolvedContactId;
                }

                Id pdTerritoryId = null;
                String durationTag = followUp ? '30' : '60';
                for (ServiceTerritoryMember stm : [
                    SELECT ServiceTerritoryId, ServiceTerritory.Name FROM ServiceTerritoryMember
                    WHERE ServiceResourceId = :pd.Id
                    AND ServiceTerritory.IsActive = true
                    AND ServiceTerritory.Name LIKE :('%' + durationTag + ' Min%')
                    AND ServiceTerritory.Assigned_Service_Resource__c = :pd.RelatedRecordId
                    AND EffectiveStartDate <= :Date.today()
                    AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :Date.today())
                    LIMIT 1
                ]) {
                    pdTerritoryId = stm.ServiceTerritoryId;
                }
                if (pdTerritoryId == null) {
                    for (ServiceTerritoryMember stm : [
                        SELECT ServiceTerritoryId FROM ServiceTerritoryMember
                        WHERE ServiceResourceId = :pd.Id
                        AND ServiceTerritory.IsActive = true
                        AND TerritoryType = 'P'
                        AND EffectiveStartDate <= :Date.today()
                        AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :Date.today())
                        ORDER BY CreatedDate ASC LIMIT 1
                    ]) {
                        pdTerritoryId = stm.ServiceTerritoryId;
                    }
                }
                if (pdTerritoryId != null) {
                    sa.ServiceTerritoryId = pdTerritoryId;
                }

                update sa;

                AssignedResource ar = new AssignedResource();
                ar.ServiceAppointmentId = sa.Id;
                ar.ServiceResourceId    = pd.Id;
                insert ar;

                try {
                    Event evt         = new Event();
                    evt.Subject       = meetingType + ' - Zenith Prep Academy';
                    evt.StartDateTime = sa.SchedStartTime;
                    evt.EndDateTime   = sa.SchedEndTime;
                    evt.OwnerId       = pd.RelatedRecordId;
                    evt.WhatId        = opp.Id;
                    if (resolvedContactId != null) {
                        evt.WhoId = resolvedContactId;
                    }
                    evt.ShowAs      = 'Busy';
                    evt.Location    = 'Zoom';
                    evt.Description = 'Strategy Overview Meeting scheduled.\n\n'
                        + 'Program Director: ' + pd.Name + '\n'
                        + 'Location: Zoom\n\n'
                        + 'Appointment ID: ' + sa.Id + '\n'
                        + 'Opportunity: '    + opp.Id;
                    tryPut(evt, 'Service_Appointment__c', sa.Id);
                    insert evt;
                } catch (Exception eventEx) {
                    System.debug(LoggingLevel.WARN, 'Event creation failed: ' + eventEx.getMessage());
                }

                try {
                    pd.Appointment_Count__c = (pd.Appointment_Count__c != null)
                        ? pd.Appointment_Count__c + 1 : 1;
                    update pd;
                } catch (Exception pdEx) {
                    System.debug(LoggingLevel.WARN, 'ServiceResource counter update failed: ' + pdEx.getMessage());
                }

                res.success           = true;
                res.pdName            = pd.Name;
                res.pdUserId          = pd.RelatedRecordId;
                res.serviceResourceId = pd.Id;

            } catch (Exception e) {
                res.success      = false;
                res.errorMessage = e.getMessage();
            }

            // -----------------------------------------------------------------
            //  Sticky PD writes on Opportunity + Contact.
            //  Critical: these live OUTSIDE the main try/catch so they always run
            //  whenever we have a resolved PD user, even if the SA / AssignedResource /
            //  counter updates above threw. This is why the original code was not
            //  writing Program_Director__c to Opp/Contact — the earlier DML would throw
            //  and skip the sticky update entirely.
            // -----------------------------------------------------------------
            if (resolvedPdUserId != null) {
                List<SObject> stickyUpdates = new List<SObject>();
                Opportunity oppUpd = new Opportunity(
                    Id = req.opportunityId, Program_Director__c = resolvedPdUserId);
                Opportunity origOpp = oppMap.get(req.opportunityId);
                if (origOpp != null && origOpp.Family_Success_Specialist__c == null && resolvedFssUserId != null) {
                    oppUpd.Family_Success_Specialist__c = resolvedFssUserId;
                }
                stickyUpdates.add(oppUpd);
                if (resolvedContactId != null) {
                    Contact conUpd = new Contact(
                        Id = resolvedContactId, Program_Director__c = resolvedPdUserId);
                    if (resolvedFssUserId != null) {
                        conUpd.Family_Success_Specialist__c = resolvedFssUserId;
                    }
                    stickyUpdates.add(conUpd);
                }
                try {
                    Database.SaveResult[] srs = Database.update(stickyUpdates, false);
                    for (Integer i = 0; i < srs.size(); i++) {
                        if (!srs[i].isSuccess()) {
                            String recType = (stickyUpdates[i] instanceof Opportunity) ? 'Opportunity' : 'Contact';
                            String err = srs[i].getErrors()[0].getMessage();
                            System.debug(LoggingLevel.ERROR, recType + ' PD sticky update failed: ' + err);
                            res.errorMessage = (res.errorMessage == null ? '' : res.errorMessage + ' | ')
                                + recType + ': ' + err;
                        }
                    }
                } catch (Exception stickyEx) {
                    System.debug(LoggingLevel.ERROR, 'Sticky PD update threw: ' + stickyEx.getMessage());
                    res.errorMessage = (res.errorMessage == null ? '' : res.errorMessage + ' | ')
                        + 'Sticky: ' + stickyEx.getMessage();
                }
            }

            // -----------------------------------------------------------------
            //  StageName update is its own DML so a validation rule or downstream
            //  flow on StageName cannot take down the Program_Director__c write.
            // -----------------------------------------------------------------
            if (res.success == true) {
                try {
                    update new Opportunity(Id = req.opportunityId, StageName = 'SOM Scheduled');
                } catch (Exception stageEx) {
                    System.debug(LoggingLevel.WARN, 'Stage update skipped: ' + stageEx.getMessage());
                }
            }

            results.add(res);
        }

        return results;
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