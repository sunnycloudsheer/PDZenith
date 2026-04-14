/**
 * ═══════════════════════════════════════════════════════════════
 * PDPostBookingHandler
 * ═══════════════════════════════════════════════════════════════
 * Invocable Apex called AFTER the ServiceAppointment is created
 * in the PD Book SOM Call flow.
 *
 * What the flow already did (before calling this handler):
 *   ✅ Created ServiceAppointment with time slot selected by user
 *      (time slot shows combined availability of ALL PDs)
 *
 * What this handler does:
 *   1. Selects a PD via sticky assignment or weighted round-robin
 *      — only considers PDs available at the booked time
 *   2. Creates AssignedResource linking SA → selected PD
 *   3. Creates Event on PD's calendar
 *   4. Sets Meeting_Type__c on the ServiceAppointment
 *   5. Stamps Assigned_PD__c on Opportunity (sticky — first PD only)
 *   6. Updates Opportunity Stage to "SOM Scheduled"
 *   7. Increments PD's Appointment_Count__c (for weighted RR)
 *
 * Called from: PD: Book SOM Call (Screen Flow),
 *              placed AFTER the Create Service Appointment element
 * ═══════════════════════════════════════════════════════════════
 */
public with sharing class PDPostBookingHandler {

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
        @InvocableVariable public String errorMessage;
        @InvocableVariable public String pdName;
        @InvocableVariable public Id pdUserId;
        @InvocableVariable public Id serviceResourceId;
    }

    @InvocableMethod(
        label='PD Post-Booking Handler'
        description='Runs after SA creation. Assigns PD via round-robin, creates AssignedResource and Event, stamps Opportunity, increments count, sets Meeting_Type.'
        category='Scheduling'
    )
    public static List<PostBookingResult> handlePostBooking(List<PostBookingRequest> requests) {
        List<PostBookingResult> results = new List<PostBookingResult>();

        // ─── Collect all Ids upfront ───
        Set<Id> saIds = new Set<Id>();
        Set<Id> oppIds = new Set<Id>();
        for (PostBookingRequest req : requests) {
            saIds.add(req.serviceAppointmentId);
            oppIds.add(req.opportunityId);
        }

        // ─── Bulk SOQL ───
        Map<Id, ServiceAppointment> saMap = new Map<Id, ServiceAppointment>([
            SELECT Id, SchedStartTime, SchedEndTime, ServiceTerritoryId,
                   ParentRecordId, ContactId, AccountId, WorkTypeId
            FROM ServiceAppointment
            WHERE Id IN :saIds
        ]);

        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>([
            SELECT Id, Assigned_PD__c, StageName, AccountId
            FROM Opportunity
            WHERE Id IN :oppIds
        ]);

        for (PostBookingRequest req : requests) {
            PostBookingResult res = new PostBookingResult();
            try {
                Boolean followUp = (req.isFollowUp != null && req.isFollowUp);
                String meetingType = followUp
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

                // ─── 1. Select PD (sticky or round-robin) ───
                Id selectedResourceId = selectPD(opp, sa.SchedStartTime, sa.SchedEndTime);
                if (selectedResourceId == null) {
                    throw new HandlerException(
                        'No available Program Director found for the selected time slot. '
                        + 'Please try a different time.'
                    );
                }

                ServiceResource pd = [
                    SELECT Id, Name, RelatedRecordId, Appointment_Count__c
                    FROM ServiceResource
                    WHERE Id = :selectedResourceId
                    LIMIT 1
                ];

                // ─── 2. Update ServiceAppointment ───
                sa.Meeting_Type__c = meetingType;
                sa.Subject = meetingType + ' - Zenith Prep Academy';
                sa.OwnerId = pd.RelatedRecordId;
                update sa;

                // ─── 3. Create AssignedResource ───
                AssignedResource ar = new AssignedResource();
                ar.ServiceAppointmentId = sa.Id;
                ar.ServiceResourceId = pd.Id;
                insert ar;

                // ─── 4. Create Event on PD's calendar ───
                try {
                    Id contactId = null;
                    List<OpportunityContactRole> ocrs = [
                        SELECT ContactId FROM OpportunityContactRole
                        WHERE OpportunityId = :opp.Id
                        AND IsPrimary = true
                        LIMIT 1
                    ];
                    if (!ocrs.isEmpty()) {
                        contactId = ocrs[0].ContactId;
                    }

                    Event evt = new Event();
                    evt.Subject = meetingType + ' - Zenith Prep Academy';
                    evt.StartDateTime = sa.SchedStartTime;
                    evt.EndDateTime = sa.SchedEndTime;
                    evt.OwnerId = pd.RelatedRecordId;
                    evt.WhatId = opp.Id;
                    if (contactId != null) {
                        evt.WhoId = contactId;
                    }
                    evt.ShowAs = 'Busy';
                    evt.Location = 'Zoom';
                    evt.Description = 'Strategy Overview Meeting scheduled.\n\n'
                        + 'Program Director: ' + pd.Name + '\n'
                        + 'Location: Zoom\n\n'
                        + 'Appointment ID: ' + sa.Id + '\n'
                        + 'Opportunity: ' + opp.Id;
                    tryPut(evt, 'Service_Appointment__c', sa.Id);
                    insert evt;
                } catch (Exception eventEx) {
                    // Event creation is non-critical — log but continue
                    System.debug(LoggingLevel.WARN, 'Event creation failed: ' + eventEx.getMessage());
                }

                // ─── 5. Stamp Assigned_PD__c on Opportunity (sticky) ───
                Boolean oppChanged = false;
                if (opp.Assigned_PD__c == null) {
                    opp.Assigned_PD__c = pd.Id;
                    oppChanged = true;
                }
                if (opp.StageName != 'SOM Scheduled') {
                    opp.StageName = 'SOM Scheduled';
                    oppChanged = true;
                }
                if (oppChanged) {
                    update opp;
                }

                // ─── 6. Increment PD's Appointment_Count__c ───
                pd.Appointment_Count__c = (pd.Appointment_Count__c != null)
                    ? pd.Appointment_Count__c + 1 : 1;
                update pd;

                // ─── Return PD info ───
                res.success = true;
                res.pdName = pd.Name;
                res.pdUserId = pd.RelatedRecordId;
                res.serviceResourceId = pd.Id;

            } catch (Exception e) {
                res.success = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }

        return results;
    }

    /**
     * ═══════════════════════════════════════════════════════════
     * selectPD
     * ═══════════════════════════════════════════════════════════
     * Determines which PD to assign:
     *   1. If Opportunity has a sticky Assigned_PD__c AND that PD
     *      is available at the booked time → use sticky PD
     *   2. Otherwise → weighted round-robin among available PDs
     * ═══════════════════════════════════════════════════════════
     */
    private static Id selectPD(Opportunity opp, DateTime startDT, DateTime endDT) {
        // ─── Check sticky assignment first ───
        if (opp.Assigned_PD__c != null) {
            List<ServiceResource> stickyCheck = [
                SELECT Id, RelatedRecordId FROM ServiceResource
                WHERE Id = :opp.Assigned_PD__c
                AND IsActive = true
                LIMIT 1
            ];
            if (!stickyCheck.isEmpty() && stickyCheck[0].RelatedRecordId != null) {
                List<User> pdUser = [
                    SELECT Id FROM User
                    WHERE Id = :stickyCheck[0].RelatedRecordId
                    AND Profile.Name = :PD_PROFILE_NAME
                    AND IsActive = true
                    LIMIT 1
                ];
                if (!pdUser.isEmpty()) {
                    if (isResourceAvailable(
                        opp.Assigned_PD__c,
                        stickyCheck[0].RelatedRecordId,
                        startDT, endDT
                    )) {
                        return opp.Assigned_PD__c;
                    }
                }
            }
        }

        // ─── Fall back to weighted round-robin ───
        return selectByWeightedRoundRobin(startDT, endDT);
    }

    /**
     * ═══════════════════════════════════════════════════════════
     * isResourceAvailable
     * ═══════════════════════════════════════════════════════════
     * Checks whether a single PD resource is free at the given
     * time by looking at ServiceAppointments, Events, and
     * ResourceAbsences.
     * ═══════════════════════════════════════════════════════════
     */
    private static Boolean isResourceAvailable(
        Id resourceId, Id userId, DateTime startDT, DateTime endDT
    ) {
        // Check ServiceAppointment conflicts
        Integer saConflicts = [
            SELECT COUNT() FROM AssignedResource
            WHERE ServiceResourceId = :resourceId
            AND ServiceAppointment.SchedStartTime < :endDT
            AND ServiceAppointment.SchedEndTime > :startDT
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
        ];
        if (saConflicts > 0) return false;

        // Check Event conflicts
        if (userId != null) {
            Integer evtConflicts = [
                SELECT COUNT() FROM Event
                WHERE OwnerId = :userId
                AND StartDateTime < :endDT
                AND EndDateTime > :startDT
                AND (ShowAs = NULL OR ShowAs != 'Free')
            ];
            if (evtConflicts > 0) return false;
        }

        // Check ResourceAbsence conflicts
        Integer absConflicts = [
            SELECT COUNT() FROM ResourceAbsence
            WHERE ResourceId = :resourceId
            AND Start < :endDT
            AND End > :startDT
        ];
        if (absConflicts > 0) return false;

        return true;
    }

    /**
     * ═══════════════════════════════════════════════════════════
     * selectByWeightedRoundRobin
     * ═══════════════════════════════════════════════════════════
     * Weighted Round-Robin among PDs available at the booked time:
     *   Effective Load = Appointment_Count__c / Weight__c
     *   Selects the available PD with the LOWEST effective load.
     *
     * Uses batch queries to check availability for all PDs at
     * once (3 SOQL queries total, not per-resource).
     * ═══════════════════════════════════════════════════════════
     */
    private static Id selectByWeightedRoundRobin(DateTime startDT, DateTime endDT) {
        // ─── Find active PD users ───
        Set<Id> pdUserIds = new Set<Id>();
        for (User u : [
            SELECT Id FROM User
            WHERE Profile.Name = :PD_PROFILE_NAME
            AND IsActive = true
        ]) {
            pdUserIds.add(u.Id);
        }
        if (pdUserIds.isEmpty()) return null;

        // ─── Find active ServiceResources for PD users ───
        List<ServiceResource> pdResources = [
            SELECT Id, Appointment_Count__c, Weight__c, RelatedRecordId
            FROM ServiceResource
            WHERE RelatedRecordId IN :pdUserIds
            AND IsActive = true
            ORDER BY CreatedDate ASC
        ];
        if (pdResources.isEmpty()) return null;

        // ─── Filter to resources with active territory memberships ───
        Set<Id> allSrIds = new Set<Id>();
        Map<Id, Id> resourceToUser = new Map<Id, Id>();
        for (ServiceResource sr : pdResources) {
            allSrIds.add(sr.Id);
            resourceToUser.put(sr.Id, sr.RelatedRecordId);
        }

        Date today = Date.today();
        Set<Id> resourcesWithTerritory = new Set<Id>();
        for (ServiceTerritoryMember stm : [
            SELECT ServiceResourceId
            FROM ServiceTerritoryMember
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

        // ─── Batch availability check (3 queries for ALL resources) ───
        Set<Id> busyResources = new Set<Id>();

        // 1. ServiceAppointment conflicts
        for (AssignedResource arec : [
            SELECT ServiceResourceId FROM AssignedResource
            WHERE ServiceResourceId IN :validIds
            AND ServiceAppointment.SchedStartTime < :endDT
            AND ServiceAppointment.SchedEndTime > :startDT
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
        ]) {
            busyResources.add(arec.ServiceResourceId);
        }

        // 2. Event conflicts
        Set<Id> validUserIds = new Set<Id>();
        for (Id resId : validIds) {
            Id userId = resourceToUser.get(resId);
            if (userId != null) validUserIds.add(userId);
        }
        if (!validUserIds.isEmpty()) {
            Set<Id> busyUsers = new Set<Id>();
            for (Event ev : [
                SELECT OwnerId FROM Event
                WHERE OwnerId IN :validUserIds
                AND StartDateTime < :endDT
                AND EndDateTime > :startDT
                AND (ShowAs = NULL OR ShowAs != 'Free')
            ]) {
                busyUsers.add(ev.OwnerId);
            }
            for (Id resId : validIds) {
                Id userId = resourceToUser.get(resId);
                if (userId != null && busyUsers.contains(userId)) {
                    busyResources.add(resId);
                }
            }
        }

        // 3. ResourceAbsence conflicts
        for (ResourceAbsence ra : [
            SELECT ResourceId FROM ResourceAbsence
            WHERE ResourceId IN :validIds
            AND Start < :endDT
            AND End > :startDT
        ]) {
            busyResources.add(ra.ResourceId);
        }

        // ─── Select lowest effective load among available resources ───
        Id bestId = null;
        Decimal bestLoad = null;

        for (ServiceResource sr : validResources) {
            if (busyResources.contains(sr.Id)) continue;

            Decimal count = (sr.Appointment_Count__c != null) ? sr.Appointment_Count__c : 0;
            Decimal weight = (sr.Weight__c != null && sr.Weight__c > 0) ? sr.Weight__c : 1.0;
            Decimal effectiveLoad = count / weight;

            if (bestLoad == null || effectiveLoad < bestLoad) {
                bestLoad = effectiveLoad;
                bestId = sr.Id;
            }
        }

        return bestId;
    }

    private static void tryPut(SObject rec, String f, Object v) {
        try { rec.put(f, v); } catch (Exception ex) { }
    }

    public class HandlerException extends Exception {}
}
