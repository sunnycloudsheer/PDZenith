public without sharing class GuestSchedulerController {

    // Custom exception used by discover() so getBookingConfig's catch can read e.getMessage().
    public class SchedulerConfigException extends Exception {}

    private static final String ADMISSION_PROFILE_NAME     = 'Admission Counsellor';
    private static final String ADMISSION_PROFILE_NAME_ALT = 'Admission Counselor';
    private static final String PD_PROFILE_NAME            = 'Program Director';
    private static final String FSS_PROFILE_NAME           = 'FSS Onboarding';
    private static final Integer DEFAULT_SCAN_DAYS     = 30;
    private static final Integer DEFAULT_ADVANCE_HOURS = 2;
    private static Map<String, DiscoveredConfig> cachedDiscoveryMap = new Map<String, DiscoveredConfig>();

    private static final Map<String, String> MEETING_TYPE_MAP = new Map<String, String>{
        'IC'    => 'Initial Consultation',
        'PD'    => 'Program Director - 60 Minutes',
        'PD-FU' => 'Program Director Follow Up',
        'FSS'   => 'FSS Onboarding'
    };
    private static final Map<String, String> SUBJECT_MAP = new Map<String, String>{
        'IC'    => 'Initial Consultation - Zenith Prep Academy',
        'PD'    => 'Program Director - 60 Minutes - Zenith Prep Academy',
        'PD-FU' => 'Program Director Follow Up - Zenith Prep Academy',
        'FSS'   => 'FSS Onboarding Meeting - Zenith Prep Academy'
    };

    private class DiscoveredConfig {
        Id workTypeId;
        String workTypeName;
        Integer durationMinutes;
        Integer slotIntervalMinutes;
        Integer timeframeEndDays;
        Integer timeframeStartDays;
        String durationType;
        String appointmentType;
        Id serviceTerritoryId;
        String territoryName;
        String territoryTimezone;
        Id operatingHoursId;
        Set<Id> allTerritoryIds = new Set<Id>();
        Id workTypeGroupId;
        String workTypeGroupName;
        String street;
        String city;
        String state;
        String bookingType;
    }

    private class ResourceBundle {
        Set<Id> resourceIds = new Set<Id>();
        List<Id> orderedResourceIds = new List<Id>();
        Map<Id,Id> resourceToUserId = new Map<Id,Id>();
        Map<Id,Id> resourceToTerritoryId = new Map<Id,Id>();
    }

    private class ResourceAssignment {
        Id resourceId;
        Id userId;
        Id territoryId;
    }

    private class SlotInfo {
        DateTime startUtc;
        DateTime endUtc;
    }

    // Normalise the booking-type code (defaults blank/IC to 'IC').
    private static String normalizeType(String bookingType) {
        if (String.isBlank(bookingType) || bookingType == 'IC') return 'IC';
        return bookingType.toUpperCase();
    }

    // Profile names that own the resources for a given booking type.
    private static List<String> getProfileNames(String bType) {
        if (bType == 'PD' || bType == 'PD-FU') return new List<String>{ PD_PROFILE_NAME };
        if (bType == 'FSS') return new List<String>{ FSS_PROFILE_NAME };
        return new List<String>{ ADMISSION_PROFILE_NAME, ADMISSION_PROFILE_NAME_ALT };
    }

    // Build DMLOptions that allow saving past duplicate rules.
    private static Database.DMLOptions dmlAllowDupes() {
        Database.DMLOptions d = new Database.DMLOptions();
        d.DuplicateRuleHeader.allowSave = true;
        d.DuplicateRuleHeader.runAsCurrentUser = false;
        return d;
    }

    // Count how many resources are free in the given UTC window.
    private static Integer countFreeResources(
        ResourceBundle rb, Map<Id, List<List<DateTime>>> rawBusy,
        DateTime slotStart, DateTime slotEnd
    ) {
        Integer freeCount = 0;
        for (Id rId : rb.resourceIds) {
            List<List<DateTime>> ivs = rawBusy.get(rId);
            Boolean free = true;
            if (ivs != null) {
                for (List<DateTime> iv : ivs) {
                    if (slotStart < iv[1] && slotEnd > iv[0]) { free = false; break; }
                }
            }
            if (free) freeCount++;
        }
        return freeCount;
    }

    // Discover the active WorkType / Territory / OperatingHours config for a booking type.
    private static DiscoveredConfig discover(String bookingType) {
        String bType = normalizeType(bookingType);
        if (cachedDiscoveryMap.containsKey(bType)) return cachedDiscoveryMap.get(bType);
        DiscoveredConfig cfg = new DiscoveredConfig();
        cfg.bookingType = bType;
        Date today = Date.today();
        Date scanEnd = today.addDays(DEFAULT_SCAN_DAYS);
        List<String> profileNames = getProfileNames(bType);

        Set<Id> userIds = new Set<Id>();
        String profileQuery = (profileNames.size() == 1) ? profileNames[0] : null;
        if (profileQuery != null) {
            for (User u : [SELECT Id FROM User WHERE Profile.Name = :profileQuery AND IsActive = true]) {
                userIds.add(u.Id);
            }
        } else {
            String p1 = profileNames[0];
            String p2 = profileNames[1];
            for (User u : [SELECT Id FROM User WHERE (Profile.Name = :p1 OR Profile.Name = :p2) AND IsActive = true]) {
                userIds.add(u.Id);
            }
        }
        if (userIds.isEmpty())
            throw new SchedulerConfigException('No active users found for ' + bType + ' booking.');

        Set<Id> resourceIds = new Set<Id>();
        for (ServiceResource sr : [
            SELECT Id FROM ServiceResource
            WHERE RelatedRecordId IN :userIds AND IsActive = true
        ]) {
            resourceIds.add(sr.Id);
        }
        if (resourceIds.isEmpty())
            throw new SchedulerConfigException('No active Service Resources found for ' + bType + ' users. '
                + 'Please ensure each ' + bType + ' user has an active Service Resource record.');

        Set<Id> rawTerritoryIds = new Set<Id>();
        for (ServiceTerritoryMember stm : [
            SELECT ServiceTerritoryId FROM ServiceTerritoryMember
            WHERE ServiceResourceId IN :resourceIds
            AND EffectiveStartDate <= :scanEnd
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
        ]) {
            rawTerritoryIds.add(stm.ServiceTerritoryId);
        }
        if (rawTerritoryIds.isEmpty())
            throw new SchedulerConfigException('No territories found for ' + bType + ' resources.');

        Integer expectedDur = expectedDurationMinutes(bType);
        if (expectedDur != null) {
            Set<Id> filtered = filterTerritoriesByDuration(rawTerritoryIds, expectedDur);
            if (!filtered.isEmpty()) rawTerritoryIds = filtered;
        }

        List<ServiceTerritory> territories = [
            SELECT Id, Name, IsActive, OperatingHoursId,
                   OperatingHours.TimeZone, Street, City, State
            FROM ServiceTerritory WHERE Id IN :rawTerritoryIds AND OperatingHoursId != null
            ORDER BY CreatedDate DESC
        ];
        if (territories.isEmpty()) {
            territories = [
                SELECT Id, Name, IsActive, OperatingHoursId,
                       OperatingHours.TimeZone, Street, City, State
                FROM ServiceTerritory WHERE Id IN :rawTerritoryIds
                ORDER BY CreatedDate DESC LIMIT 1
            ];
        }
        if (territories.isEmpty()) throw new SchedulerConfigException('No ServiceTerritory found for ' + bType + '.');

        ServiceTerritory st = territories[0];
        if (territories.size() > 1) {
            Map<Id, Id> tToOH = new Map<Id, Id>();
            for (ServiceTerritory t : territories) {
                if (t.OperatingHoursId != null) tToOH.put(t.Id, t.OperatingHoursId);
            }
            if (!tToOH.isEmpty()) {
                Set<Id> ohIds = new Set<Id>(tToOH.values());
                Map<Id, Integer> ohCount = new Map<Id, Integer>();
                for (TimeSlot ts : [SELECT OperatingHoursId FROM TimeSlot WHERE OperatingHoursId IN :ohIds]) {
                    Integer c = ohCount.containsKey(ts.OperatingHoursId) ? ohCount.get(ts.OperatingHoursId) + 1 : 1;
                    ohCount.put(ts.OperatingHoursId, c);
                }
                Integer bestCount = 0;
                for (ServiceTerritory t : territories) {
                    if (t.OperatingHoursId == null) continue;
                    Integer c = ohCount.containsKey(t.OperatingHoursId) ? ohCount.get(t.OperatingHoursId) : 0;
                    if (c > bestCount) { bestCount = c; st = t; }
                }
            }
        }

        Id opHoursId = st.OperatingHoursId;
        String tzStr = (st.OperatingHours != null) ? st.OperatingHours.TimeZone : null;
        if (opHoursId == null) {
            for (ServiceTerritoryMember stm : [
                SELECT OperatingHoursId, OperatingHours.TimeZone
                FROM ServiceTerritoryMember
                WHERE ServiceTerritoryId = :st.Id
                AND ServiceResourceId IN :resourceIds
                AND OperatingHoursId != NULL LIMIT 1
            ]) {
                opHoursId = stm.OperatingHoursId;
                tzStr = stm.OperatingHours.TimeZone;
            }
        }
        if (opHoursId == null)
            throw new SchedulerConfigException('No OperatingHours on territory "' + st.Name + '".');

        cfg.serviceTerritoryId = st.Id;
        cfg.territoryName = st.Name;
        cfg.territoryTimezone = tzStr != null ? tzStr : 'America/Chicago';
        cfg.operatingHoursId = opHoursId;
        cfg.street = st.Street;
        cfg.city = st.City;
        cfg.state = st.State;
        cfg.allTerritoryIds = rawTerritoryIds;

        WorkType wt = null;
        List<WorkType> wtsByOH = [
            SELECT Id, Name, DurationInMinutes, DurationType, DefaultAppointmentType,
                   ApptStartTimeIntvlInMin, TimeframeEnd, TimeFrameEndUnit,
                   TimeframeStart, TimeFrameStartUnit
            FROM WorkType WHERE OperatingHoursId = :opHoursId
            ORDER BY CreatedDate DESC
        ];
        if (!wtsByOH.isEmpty()) {
            if (expectedDur != null) {
                for (WorkType candidate : wtsByOH) {
                    Integer cMins = workTypeDurationInMinutes(
                        candidate.DurationInMinutes, candidate.DurationType);
                    if (cMins != null && cMins == expectedDur) { wt = candidate; break; }
                }
            }
            if (wt == null) wt = wtsByOH[0];
        }
        if (wt == null) {
            try {
                for (ServiceTerritoryWorkType stwt : [
                    SELECT WorkType.Id, WorkType.Name, WorkType.DurationInMinutes,
                           WorkType.DurationType, WorkType.DefaultAppointmentType,
                           WorkType.ApptStartTimeIntvlInMin, WorkType.TimeframeEnd,
                           WorkType.TimeFrameEndUnit, WorkType.TimeframeStart,
                           WorkType.TimeFrameStartUnit
                    FROM ServiceTerritoryWorkType
                    WHERE ServiceTerritoryId IN :rawTerritoryIds
                    ORDER BY CreatedDate DESC LIMIT 1
                ]) { wt = stwt.WorkType; }
            } catch (Exception e) { }
        }
        if (wt == null) {
            List<WorkType> anyWTs = [
                SELECT Id, Name, DurationInMinutes, DurationType, DefaultAppointmentType,
                       ApptStartTimeIntvlInMin, TimeframeEnd, TimeFrameEndUnit,
                       TimeframeStart, TimeFrameStartUnit
                FROM WorkType ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (!anyWTs.isEmpty()) wt = anyWTs[0];
        }
        if (wt == null) throw new SchedulerConfigException('No WorkType found.');

        cfg.workTypeId = wt.Id;
        cfg.workTypeName = wt.Name;
        cfg.durationType = wt.DurationType;
        cfg.appointmentType = wt.DefaultAppointmentType;

        if (bType == 'PD') {
            cfg.durationMinutes = 60;
            cfg.slotIntervalMinutes = 45;
        } else if (bType == 'PD-FU') {
            cfg.durationMinutes = 30;
            cfg.slotIntervalMinutes = 30;
        } else if (bType == 'FSS') {
            cfg.durationMinutes = 30;
            cfg.slotIntervalMinutes = 30;
        } else {
            cfg.durationMinutes = 60;
            cfg.slotIntervalMinutes = (wt.ApptStartTimeIntvlInMin != null && wt.ApptStartTimeIntvlInMin > 0)
                ? wt.ApptStartTimeIntvlInMin : 60;
        }
        cfg.timeframeEndDays = DEFAULT_SCAN_DAYS;
        if (wt.TimeframeEnd != null && wt.TimeframeEnd > 0)
            cfg.timeframeEndDays = (wt.TimeFrameEndUnit == 'Days')
                ? wt.TimeframeEnd : Math.max(1, (wt.TimeframeEnd + 23) / 24);
        cfg.timeframeStartDays = 0;
        if (wt.TimeframeStart != null && wt.TimeframeStart > 0 && wt.TimeFrameStartUnit == 'Days')
            cfg.timeframeStartDays = wt.TimeframeStart;

        try {
            for (WorkTypeGroupMember wtgm : [
                SELECT WorkTypeGroupId, WorkTypeGroup.Name
                FROM WorkTypeGroupMember WHERE WorkTypeId = :wt.Id LIMIT 1
            ]) {
                cfg.workTypeGroupId = wtgm.WorkTypeGroupId;
                cfg.workTypeGroupName = wtgm.WorkTypeGroup.Name;
            }
        } catch (Exception e) { }

        cachedDiscoveryMap.put(bType, cfg);
        return cfg;
    }

    // Resolve the resource originally assigned to the SA / Lead so reschedules stay sticky.
    private static Id findStickyResourceForReschedule(String rescheduleToken) {
        if (String.isBlank(rescheduleToken)) return null;
        try {
            List<ServiceAppointment> origs = [
                SELECT Id, Admission_Counselor__c, OwnerId
                FROM ServiceAppointment
                WHERE Reschedule_Token__c = :rescheduleToken
                LIMIT 1
            ];
            if (!origs.isEmpty()) {
                Id origSAId = origs[0].Id;
                for (AssignedResource ar : [
                    SELECT ServiceResourceId, ServiceResource.IsActive
                    FROM AssignedResource
                    WHERE ServiceAppointmentId = :origSAId
                    ORDER BY CreatedDate ASC LIMIT 1
                ]) {
                    if (ar.ServiceResource != null && ar.ServiceResource.IsActive == true) {
                        return ar.ServiceResourceId;
                    }
                }
                Id userId = origs[0].Admission_Counselor__c;
                if (userId == null && origs[0].OwnerId != null
                    && String.valueOf(origs[0].OwnerId).startsWith('005')) {
                    userId = origs[0].OwnerId;
                }
                if (userId != null) {
                    List<ServiceResource> srs = [
                        SELECT Id FROM ServiceResource
                        WHERE RelatedRecordId = :userId AND IsActive = true LIMIT 1
                    ];
                    if (!srs.isEmpty()) return srs[0].Id;
                }
                return null;
            }
            Lead leadRebook = lookupLeadByRebookToken(rescheduleToken);
            if (leadRebook != null && leadRebook.Assigned_Admission_Counsellor__c != null) {
                List<ServiceResource> srs = [
                    SELECT Id FROM ServiceResource
                    WHERE RelatedRecordId = :leadRebook.Assigned_Admission_Counsellor__c
                      AND IsActive = true LIMIT 1
                ];
                if (!srs.isEmpty()) return srs[0].Id;
            }
        } catch (Exception e) { }
        return null;
    }

    // Build the Lead-rebook context map (mirrors SA-reschedule context) for getBookingConfig.
    private static Map<String, Object> buildLeadRebookContext(String rescheduleToken) {
        Lead lead = lookupLeadByRebookToken(rescheduleToken);
        if (lead == null) return null;

        Map<String, Object> out = new Map<String, Object>();
        out.put('isRescheduling', true);
        out.put('isLeadRebook', true);
        out.put('leadId', String.valueOf(lead.Id));

        if (lead.Assigned_Admission_Counsellor__c != null) {
            try {
                List<User> acUsers = [
                    SELECT Id, Name, FirstName, LastName
                    FROM User
                    WHERE Id = :lead.Assigned_Admission_Counsellor__c
                    LIMIT 1
                ];
                if (!acUsers.isEmpty()) {
                    String displayName = composeUserName(
                        acUsers[0].FirstName, acUsers[0].LastName, acUsers[0].Name);
                    if (String.isNotBlank(displayName)) {
                        out.put('counselorName', displayName);
                    }
                }
            } catch (Exception ignored) { }
        }

        Map<String, String> ci = new Map<String, String>();
        ci.put('firstName', lead.FirstName != null ? lead.FirstName : '');
        ci.put('lastName',  lead.LastName  != null ? lead.LastName  : '');
        ci.put('email',     lead.Email     != null ? lead.Email     : '');
        ci.put('phone',     lead.Phone     != null ? lead.Phone     : '');
        try {
            Object g = lead.get('Student_Grade__c');
            ci.put('studentGrade', g != null ? String.valueOf(g) : '');
        } catch (Exception ignored) { ci.put('studentGrade', ''); }
        out.put('rescheduleContactInfo', ci);

        return out;
    }

    // Look up a Lead by its first-time IC_Schedule_Token__c (single-use, post-SA-link is dead).
    private static Lead lookupLeadByScheduleToken(String token) {
        if (String.isBlank(token)) return null;
        try {
            String soql =
                'SELECT Id, FirstName, LastName, Email, Phone, OwnerId, '
              + '       Assigned_Admission_Counsellor__c, '
              + '       Service_Appointment__c, '
              + '       Student_Grade__c '
              + 'FROM Lead WHERE IC_Schedule_Token__c = :token LIMIT 1';
            List<Lead> hits = (List<Lead>) Database.query(soql);
            if (hits.isEmpty()) return null;
            Lead l = hits[0];
            try {
                Object saId = l.get('Service_Appointment__c');
                if (saId != null && String.isNotBlank(String.valueOf(saId))) return null;
            } catch (Exception ignored) { }
            return l;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'lookupLeadByScheduleToken failed: ' + e.getMessage());
            return null;
        }
    }

    // Build the Lead first-schedule context (form pre-fill, no rebook-window override).
    private static Map<String, Object> buildLeadScheduleContext(String scheduleToken) {
        Lead lead = lookupLeadByScheduleToken(scheduleToken);
        if (lead == null) return null;

        Map<String, Object> out = new Map<String, Object>();
        out.put('isRescheduling', true);
        out.put('isLeadFirstSchedule', true);
        out.put('leadId', String.valueOf(lead.Id));

        Map<String, String> ci = new Map<String, String>();
        ci.put('firstName', lead.FirstName != null ? lead.FirstName : '');
        ci.put('lastName',  lead.LastName  != null ? lead.LastName  : '');
        ci.put('email',     lead.Email     != null ? lead.Email     : '');
        ci.put('phone',     lead.Phone     != null ? lead.Phone     : '');
        try {
            Object g = lead.get('Student_Grade__c');
            ci.put('studentGrade', g != null ? String.valueOf(g) : '');
        } catch (Exception ignored) { ci.put('studentGrade', ''); }
        out.put('rescheduleContactInfo', ci);

        return out;
    }

    // Look up a Lead by its single-use IC_Reschedule_Token__c (post-cancel rebook).
    private static Lead lookupLeadByRebookToken(String token) {
        if (String.isBlank(token)) return null;
        try {
            String soql =
                'SELECT Id, FirstName, LastName, Email, Phone, OwnerId, '
              + '       Assigned_Admission_Counsellor__c, IC_Meeting_Rescheduled__c, '
              + '       Student_Grade__c '
              + 'FROM Lead WHERE IC_Reschedule_Token__c = :token LIMIT 1';
            List<Lead> hits = (List<Lead>) Database.query(soql);
            if (hits.isEmpty()) return null;
            Lead l = hits[0];
            try {
                Object already = l.get('IC_Meeting_Rescheduled__c');
                if (already == true) return null;
            } catch (Exception ignored) { }
            return l;
        } catch (Exception e) {
            return null;
        }
    }

    // Restrict a ResourceBundle to a single resource (used to lock reschedules to the original AC).
    private static ResourceBundle restrictBundleToResource(ResourceBundle rb, Id resourceId) {
        ResourceBundle stickyRb = new ResourceBundle();
        stickyRb.resourceIds.add(resourceId);
        stickyRb.orderedResourceIds.add(resourceId);
        stickyRb.resourceToUserId.put(resourceId, rb.resourceToUserId.get(resourceId));
        stickyRb.resourceToTerritoryId.put(resourceId, rb.resourceToTerritoryId.get(resourceId));
        return stickyRb;
    }

    // For PD: find the sticky resource based on the Opportunity / Contact's assigned PD.
    private static Id findStickyResourceForContact(String contactId, String opportunityId) {
        if (String.isNotBlank(opportunityId)) {
            try {
                List<Opportunity> opps = [SELECT Program_Director__c FROM Opportunity WHERE Id = :opportunityId LIMIT 1];
                if (!opps.isEmpty() && opps[0].Program_Director__c != null) {
                    List<ServiceResource> srs = [SELECT Id FROM ServiceResource
                        WHERE RelatedRecordId = :opps[0].Program_Director__c AND IsActive = true LIMIT 1];
                    if (!srs.isEmpty()) return srs[0].Id;
                }
            } catch (Exception e) { }
        }
        if (String.isNotBlank(contactId)) {
            try {
                List<Contact> cons = [SELECT Program_Director__c FROM Contact WHERE Id = :contactId LIMIT 1];
                if (!cons.isEmpty() && cons[0].Program_Director__c != null) {
                    List<ServiceResource> srs = [SELECT Id FROM ServiceResource
                        WHERE RelatedRecordId = :cons[0].Program_Director__c AND IsActive = true LIMIT 1];
                    if (!srs.isEmpty()) return srs[0].Id;
                }
            } catch (Exception e) { }
        }
        return null;
    }

    // Returns the LWC's booking config (workType, durations, available dates, reschedule context).
    @AuraEnabled
    public static Map<String, Object> getBookingConfig(Integer openWindowDays, String bookingType,
                                                        String contactId, String opportunityId, String token,
                                                        String rescheduleToken) {
        Map<String, Object> out = new Map<String, Object>();
        try {
            Boolean isRescheduling = false;
            if (String.isNotBlank(rescheduleToken)) {
                List<ServiceAppointment> origs = [
                    SELECT Id, Status, SchedStartTime, ContactId, ParentRecordId,
                           Meeting_Type__c, Opportunity__c,
                           OwnerId, Owner.Name, Owner.FirstName, Owner.LastName,
                           Admission_Counselor__c,
                           Admission_Counselor__r.Name,
                           Admission_Counselor__r.FirstName, Admission_Counselor__r.LastName,
                           Program_Director__c,
                           Program_Director__r.Name,
                           Program_Director__r.FirstName, Program_Director__r.LastName,
                           Family_Success_Specialist__c,
                           Family_Success_Specialist__r.Name,
                           Family_Success_Specialist__r.FirstName, Family_Success_Specialist__r.LastName
                    FROM ServiceAppointment
                    WHERE Reschedule_Token__c = :rescheduleToken
                    LIMIT 1
                ];
                Boolean isLeadRebook = false;
                Boolean isLeadFirstSchedule = false;
                ServiceAppointment orig = null;
                if (origs.isEmpty()) {
                    Map<String, Object> leadRebookCtx = buildLeadRebookContext(rescheduleToken);
                    if (leadRebookCtx != null) {
                        out.putAll(leadRebookCtx);
                        bookingType = 'IC';
                        isRescheduling = true;
                        isLeadRebook = true;
                    } else {
                        Map<String, Object> leadScheduleCtx =
                            buildLeadScheduleContext(rescheduleToken);
                        if (leadScheduleCtx == null) {
                            out.put('success', false);
                            out.put('error', 'LINK_ALREADY_USED');
                            return out;
                        }
                        out.putAll(leadScheduleCtx);
                        bookingType = 'IC';
                        isRescheduling = true;
                        isLeadFirstSchedule = true;
                    }
                } else {
                    orig = origs[0];
                }
                if (orig != null) {
                    if (orig.Status == 'Canceled' || orig.Status == 'Completed' || orig.Status == 'Cannot Complete') {
                        out.put('success', false);
                        out.put('error', 'LINK_ALREADY_USED');
                        return out;
                    }
                    if (orig.SchedStartTime != null && orig.SchedStartTime < DateTime.now().addHours(-1)) {
                        out.put('success', false);
                        out.put('error', 'APPOINTMENT_PASSED');
                        return out;
                    }
                    String mt = (orig.Meeting_Type__c != null) ? orig.Meeting_Type__c : '';
                    if (mt.startsWith('Program Director')) bookingType = 'PD';
                    else if (mt.startsWith('FSS')) bookingType = 'FSS';
                    else bookingType = 'IC';
                    contactId = (orig.ContactId != null) ? String.valueOf(orig.ContactId) : contactId;
                    opportunityId = (orig.Opportunity__c != null)
                        ? String.valueOf(orig.Opportunity__c) : opportunityId;
                    isRescheduling = true;
                    out.put('isRescheduling', true);
                    out.put('originalAppointmentId', orig.Id);
                    out.put('originalStartTime', orig.SchedStartTime != null
                        ? orig.SchedStartTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : null);
                    String assignedName = null;
                    String mtForName = (orig.Meeting_Type__c != null) ? orig.Meeting_Type__c : '';
                    if (mtForName.startsWith('Program Director')
                        && orig.Program_Director__r != null) {
                        assignedName = composeUserName(
                            orig.Program_Director__r.FirstName,
                            orig.Program_Director__r.LastName,
                            orig.Program_Director__r.Name);
                    } else if (mtForName.startsWith('FSS')
                        && orig.Family_Success_Specialist__r != null) {
                        assignedName = composeUserName(
                            orig.Family_Success_Specialist__r.FirstName,
                            orig.Family_Success_Specialist__r.LastName,
                            orig.Family_Success_Specialist__r.Name);
                    } else if (orig.Admission_Counselor__r != null) {
                        assignedName = composeUserName(
                            orig.Admission_Counselor__r.FirstName,
                            orig.Admission_Counselor__r.LastName,
                            orig.Admission_Counselor__r.Name);
                    }
                    if (String.isBlank(assignedName) && orig.Owner != null) {
                        assignedName = composeUserName(
                            orig.Owner.FirstName, orig.Owner.LastName, orig.Owner.Name);
                    }
                    if (String.isNotBlank(assignedName)) {
                        out.put('counselorName', assignedName);
                    }

                    if (bookingType == 'IC' && orig.ParentRecordId != null
                        && String.valueOf(orig.ParentRecordId).startsWith('00Q')) {
                        try {
                            List<Lead> leads = [
                                SELECT FirstName, LastName, Email, Phone
                                FROM Lead WHERE Id = :orig.ParentRecordId LIMIT 1
                            ];
                            if (!leads.isEmpty()) {
                                Lead l = leads[0];
                                Map<String, String> ci = new Map<String, String>();
                                ci.put('firstName', l.FirstName != null ? l.FirstName : '');
                                ci.put('lastName', l.LastName != null ? l.LastName : '');
                                ci.put('email', l.Email != null ? l.Email : '');
                                ci.put('phone', l.Phone != null ? l.Phone : '');
                                try {
                                    Object g = l.get('Student_Grade__c');
                                    ci.put('studentGrade', g != null ? String.valueOf(g) : '');
                                } catch (Exception gex) { ci.put('studentGrade', ''); }
                                out.put('rescheduleContactInfo', ci);
                            }
                        } catch (Exception ex) { }
                    }
                }
                if (isLeadRebook) {
                    openWindowDays = 8;
                }
            } else if (String.isBlank(contactId) && String.isNotBlank(token)) {
                try {
                    Map<String, String> decoded = BookingTokenUtil.decrypt(token);
                    contactId = decoded.get('contactId');
                    opportunityId = decoded.get('opportunityId');
                } catch (Exception te) { }
            }
            out.put('contactId', contactId);
            out.put('opportunityId', opportunityId);
            DiscoveredConfig cfg = discover(bookingType);

            if (!isRescheduling && isOneTimeUseType(cfg.bookingType) && String.isNotBlank(opportunityId)
                && isLinkAlreadyUsed(opportunityId, cfg.bookingType)) {
                out.put('success', false);
                out.put('error', 'LINK_ALREADY_USED');
                return out;
            }
            Integer targetDays = (openWindowDays != null && openWindowDays > 0)
                ? openWindowDays : cfg.timeframeEndDays;

            Boolean isSticky = false;
            Id stickyResourceId = null;
            if (cfg.bookingType == 'PD') {
                stickyResourceId = findStickyResourceForContact(contactId, opportunityId);
                isSticky = (stickyResourceId != null);
            }

            out.put('bookingType', cfg.bookingType);
            out.put('workTypeId', cfg.workTypeId);
            out.put('workTypeName', cfg.workTypeName);
            out.put('durationMinutes', cfg.durationMinutes);
            out.put('slotIntervalMinutes', cfg.slotIntervalMinutes);
            out.put('durationType', cfg.durationType);
            out.put('appointmentType', cfg.appointmentType);
            out.put('serviceTerritoryId', cfg.serviceTerritoryId);
            out.put('territoryTimezone', cfg.territoryTimezone);
            out.put('operatingHoursId', cfg.operatingHoursId);
            out.put('workTypeGroupId', cfg.workTypeGroupId);
            out.put('targetAvailDays', targetDays);
            out.put('street', cfg.street);
            out.put('city', cfg.city);
            out.put('state', cfg.state);
            out.put('meetingType', MEETING_TYPE_MAP.get(cfg.bookingType));
            out.put('isSticky', isSticky);
            out.put('stickyResourceId', stickyResourceId);
            out.put('availableDates', computeAvailableDates(cfg, targetDays));
            out.put('success', true);
        } catch (SchedulerConfigException sce) {
            String bType = normalizeType(bookingType);
            Integer expectedDur = expectedDurationMinutes(bType);
            Integer dur = (expectedDur != null) ? expectedDur : 60;
            out.put('bookingType', bType);
            out.put('durationMinutes', dur);
            out.put('slotIntervalMinutes', dur);
            out.put('targetAvailDays', DEFAULT_SCAN_DAYS);
            out.put('territoryTimezone', 'America/Chicago');
            out.put('meetingType', MEETING_TYPE_MAP.get(bType));
            out.put('availableDates', new List<String>());
            out.put('isSticky', false);
            out.put('stickyResourceId', null);
            out.put('configMessage', sce.getMessage());
            out.put('success', true);
        } catch (Exception e) {
            out.put('success', false);
            out.put('error', e.getMessage());
        }
        return out;
    }

    // Guest-accessible wrapper that validates an SA reschedule/cancel token.
    @AuraEnabled
    public static Map<String, Object> validateAppointmentByToken(String token) {
        return RescheduleTokenService.validateAndGetAppointment(token);
    }

    // Guest-accessible wrapper that cancels an SA via its reschedule token.
    @AuraEnabled
    public static Map<String, String> cancelAppointmentByToken(String token, String reason) {
        return RescheduleTokenService.cancelAppointment(token, reason);
    }

    // Returns the available start times for a given date and booking type.
    @AuraEnabled
    public static List<Map<String, String>> getAvailableSlots(String dateStr, String bookingType,
                                                               String contactId, String opportunityId,
                                                               String rescheduleToken) {
        List<Map<String, String>> result = new List<Map<String, String>>();
        try {
            DiscoveredConfig cfg = discover(bookingType);
            Date reqDate = Date.valueOf(dateStr);
            String tzId = cfg.territoryTimezone;
            TimeZone tz = TimeZone.getTimeZone(tzId);
            Date today = Date.today();
            Date scanEnd = today.addDays(cfg.timeframeEndDays - 1);

            Map<String, List<TimeSlot>> slotsByDay = loadOperatingHours(cfg.operatingHoursId);
            ResourceBundle rb = loadResources(cfg.allTerritoryIds, today, scanEnd, cfg.bookingType);
            if (rb.resourceIds.isEmpty()) return result;

            Id stickyResourceId = findStickyResourceForReschedule(rescheduleToken);
            if (stickyResourceId != null && rb.resourceIds.contains(stickyResourceId)) {
                rb = restrictBundleToResource(rb, stickyResourceId);
            } else if (cfg.bookingType == 'PD') {
                Id stickyId = findStickyResourceForContact(contactId, opportunityId);
                if (stickyId != null && rb.resourceIds.contains(stickyId)) {
                    rb = restrictBundleToResource(rb, stickyId);
                }
            }

            DateTime dayStart = localToUtc(reqDate, 0, tz);
            DateTime dayEnd = localToUtc(reqDate.addDays(1), 0, tz);
            Map<Id, List<List<DateTime>>> rawBusy =
                buildRawBusyMap(rb, cfg.allTerritoryIds, dayStart.addHours(-2), dayEnd.addHours(2));

            List<SlotInfo> candidateSlots = generateSlotsForDate(
                reqDate, cfg.durationMinutes, cfg.slotIntervalMinutes,
                cfg.timeframeStartDays, slotsByDay, rb, rawBusy, tz, tzId);

            for (SlotInfo si : candidateSlots) {
                Integer freeCount = countFreeResources(rb, rawBusy, si.startUtc, si.endUtc);
                if (freeCount > 0) {
                    result.add(new Map<String, String>{
                        'startUtc' => si.startUtc.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
                        'endUtc' => si.endUtc.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
                    });
                }
            }
        } catch (Exception e) { }
        return result;
    }

    // Books (or reschedules) an IC / PD / FSS appointment from the LWC form.
    @AuraEnabled
    public static Map<String, String> bookAppointment(
        String startTimeISO, String endTimeISO,
        String firstName, String lastName, String email, String phone,
        String studentGrade, String leadSource, String guestEmails,
        String clientTimezone, String utmSource, String utmCampaign, String utmMedium,
        String utmAd, String utmAdSet,
        String bookingType, String contactId, String opportunityId,
        String rescheduleToken, String notes,
        String landingPageSource
    ) {
        Map<String, String> res = new Map<String, String>();
        Savepoint sp = Database.setSavepoint();
        try {
            String bType = normalizeType(bookingType);
            DateTime startDT = parseISO(startTimeISO);
            DateTime endDT = parseISO(endTimeISO);

            ServiceAppointment originalSA = null;
            Lead leadRebook = null;
            Boolean isReschedule = String.isNotBlank(rescheduleToken);
            if (isReschedule) {
                List<ServiceAppointment> origs = [
                    SELECT Id, Status, ContactId, AccountId, ParentRecordId, ParentRecordType,
                           Meeting_Type__c, Opportunity__c
                    FROM ServiceAppointment
                    WHERE Reschedule_Token__c = :rescheduleToken
                    LIMIT 1
                    FOR UPDATE
                ];
                if (origs.isEmpty()) {
                    leadRebook = lookupLeadByRebookToken(rescheduleToken);
                    Lead leadFirstSchedule = null;
                    if (leadRebook == null) {
                        leadFirstSchedule = lookupLeadByScheduleToken(rescheduleToken);
                        if (leadFirstSchedule == null) {
                            res.put('success', 'false');
                            res.put('error', 'LINK_ALREADY_USED');
                            return res;
                        }
                    }
                    bType = 'IC';
                    DiscoveredConfig cfgLead = discover(bType);
                    ResourceAssignment leadAssignment = findAvailableResourceRoundRobin(
                        cfgLead, startDT, endDT, bType, null, rescheduleToken);
                    if (leadAssignment == null) {
                        res.put('success', 'false');
                        res.put('error', 'SLOT_UNAVAILABLE');
                        return res;
                    }
                    if (leadRebook != null) {
                        rebookICFromLead(res, cfgLead, leadAssignment, leadRebook,
                                         startDT, endDT, clientTimezone, landingPageSource);
                    } else {
                        bookICFromScheduleToken(res, cfgLead, leadAssignment,
                                                leadFirstSchedule, startDT, endDT,
                                                clientTimezone, landingPageSource);
                    }
                    return res;
                }
                originalSA = origs[0];
                if (originalSA.Status == 'Canceled' || originalSA.Status == 'Completed'
                    || originalSA.Status == 'Cannot Complete') {
                    res.put('success', 'false');
                    res.put('error', 'LINK_ALREADY_USED');
                    return res;
                }
                String mt = (originalSA.Meeting_Type__c != null) ? originalSA.Meeting_Type__c : '';
                if (mt.startsWith('Program Director')) bType = 'PD';
                else if (mt.startsWith('FSS')) bType = 'FSS';
                else bType = 'IC';
                if (String.isBlank(contactId) && originalSA.ContactId != null) {
                    contactId = String.valueOf(originalSA.ContactId);
                }
                if (String.isBlank(opportunityId) && originalSA.Opportunity__c != null) {
                    opportunityId = String.valueOf(originalSA.Opportunity__c);
                }
            }

            DiscoveredConfig cfg = discover(bType);

            if (!isReschedule && isOneTimeUseType(bType) && String.isNotBlank(opportunityId)
                && isLinkAlreadyUsedForUpdate(opportunityId, bType)) {
                res.put('success', 'false');
                res.put('error', 'LINK_ALREADY_USED');
                return res;
            }

            Boolean isICInPlaceReschedule = isReschedule && originalSA != null
                && bType == 'IC'
                && originalSA.ParentRecordType == 'Lead'
                && originalSA.ParentRecordId != null;

            if (!isICInPlaceReschedule && isReschedule && originalSA != null) {
                ServiceAppointment cancelOrig = new ServiceAppointment(Id = originalSA.Id);
                cancelOrig.Status = 'Canceled';
                cancelOrig.Reschedule_Token__c = null;
                RescheduleTokenService.tryPutCancellationReason(cancelOrig, 'Rescheduled by user');
                try { cancelOrig.Description = 'Rescheduled by user.'; } catch (Exception ex) { }
                update cancelOrig;
                try {
                    List<Event> origEvents = [SELECT Id FROM Event WHERE Service_Appointment__c = :originalSA.Id];
                    if (!origEvents.isEmpty()) delete origEvents;
                } catch (Exception ex) { }
                try {
                    System.enqueueJob(new ZoomMeetingManager.ZoomCancelQueueable(
                        new Set<Id>{ originalSA.Id }
                    ));
                } catch (Exception ex) { }
            }

            ResourceAssignment assignment = findAvailableResourceRoundRobin(
                cfg, startDT, endDT, bType, opportunityId, rescheduleToken);
            if (assignment == null) {
                if (isReschedule) Database.rollback(sp);
                res.put('success', 'false');
                res.put('error', 'SLOT_UNAVAILABLE');
                return res;
            }

            if (isICInPlaceReschedule) {
                rescheduleICInPlace(res, originalSA, startDT, endDT, landingPageSource);
            } else if (bType == 'IC') {
                bookIC(res, cfg, assignment, startDT, endDT,
                       firstName, lastName, email, phone, studentGrade,
                       leadSource, guestEmails, clientTimezone,
                       utmSource, utmCampaign, utmMedium,
                       utmAd, utmAdSet, notes, landingPageSource);
            } else {
                bookPDorFSS(res, cfg, assignment, bType, startDT, endDT,
                            contactId, opportunityId, clientTimezone,
                            guestEmails, notes, landingPageSource);
            }

            if (!isICInPlaceReschedule && isReschedule && originalSA != null
                && 'true'.equals(res.get('success'))) {
                res.put('rescheduledFromId', originalSA.Id);
                try {
                    String newSAId = res.get('appointmentId');
                    if (newSAId != null) {
                        ServiceAppointment annotateNew = new ServiceAppointment(Id = newSAId);
                        annotateNew.Description = 'Rescheduled from: ' + originalSA.Id;
                        update annotateNew;
                        ServiceAppointment annotateOrig = new ServiceAppointment(Id = originalSA.Id);
                        annotateOrig.Description = 'Rescheduled by user. New appointment: ' + newSAId;
                        update annotateOrig;
                    }
                } catch (Exception ex) { }
            }

        } catch (AuraHandledException ae) {
            Database.rollback(sp);
            throw ae;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Problem saving booking: ' + e.getMessage());
        }
        return res;
    }

    // In-place IC reschedule: update the existing SA times, keep the same Lead/Event/Zoom.
    private static void rescheduleICInPlace(
        Map<String, String> res, ServiceAppointment originalSA,
        DateTime startDT, DateTime endDT, String landingPageSource
    ) {
        DateTime saEndDT = startDT.addMinutes(60);
        String newToken = RescheduleTokenService.generateToken();

        ServiceAppointment saUpd = new ServiceAppointment(Id = originalSA.Id);
        saUpd.SchedStartTime         = startDT;
        saUpd.SchedEndTime           = saEndDT;
        saUpd.EarliestStartTime      = startDT;
        saUpd.DueDate                = saEndDT;
        saUpd.ArrivalWindowStartTime = startDT;
        saUpd.ArrivalWindowEndTime   = saEndDT;
        saUpd.Reschedule_Token__c    = newToken;
        if (String.isNotBlank(landingPageSource)) {
            tryPut(saUpd, 'Landing_Page_Source__c', landingPageSource);
        }
        update saUpd;

        if (originalSA.ParentRecordId != null
            && String.valueOf(originalSA.ParentRecordId).startsWith('00Q')) {
            try {
                Lead l = new Lead(Id = originalSA.ParentRecordId);
                tryPut(l, 'Scheduled_Meeting_DateTime__c', startDT);
                update l;
            } catch (Exception ex) { }
        }

        try {
            List<Event> events = [
                SELECT Id, StartDateTime, EndDateTime
                FROM Event WHERE Service_Appointment__c = :originalSA.Id
            ];
            for (Event e : events) {
                e.StartDateTime = startDT;
                e.EndDateTime   = saEndDT;
            }
            if (!events.isEmpty()) update events;
        } catch (Exception ex) { }

        res.put('success', 'true');
        res.put('appointmentId', originalSA.Id);
        if (originalSA.ParentRecordId != null) {
            res.put('leadId', String.valueOf(originalSA.ParentRecordId));
        }
        stampActionUrls(res, newToken);
    }

    // Lead-side rebook after IC cancel: reuse the Lead, create a new SA, single-use the token.
    private static void rebookICFromLead(
        Map<String, String> res, DiscoveredConfig cfg, ResourceAssignment assignment,
        Lead leadRebook, DateTime startDT, DateTime endDT, String clientTimezone,
        String landingPageSource
    ) {
        Id saTerritoryId = (assignment.territoryId != null)
            ? assignment.territoryId : cfg.serviceTerritoryId;
        DateTime saEndDT = startDT.addMinutes(60);

        ServiceAppointment sa = new ServiceAppointment();
        sa.ParentRecordId = leadRebook.Id;
        sa.ServiceTerritoryId = saTerritoryId;
        sa.WorkTypeId = cfg.workTypeId;
        sa.EarliestStartTime = startDT;
        sa.DueDate = saEndDT;
        sa.SchedStartTime = startDT;
        sa.SchedEndTime = saEndDT;
        sa.ArrivalWindowStartTime = startDT;
        sa.ArrivalWindowEndTime = saEndDT;
        sa.DurationType = cfg.durationType;
        sa.AppointmentType = cfg.appointmentType;
        sa.Status = 'Scheduled';
        sa.Subject = SUBJECT_MAP.get('IC');
        sa.Street = cfg.street;
        sa.City = cfg.city;
        sa.State = cfg.state;
        sa.Phone = leadRebook.Phone;
        sa.Email = leadRebook.Email;
        sa.Meeting_Type__c = MEETING_TYPE_MAP.get('IC');
        sa.AdditionalInformation = cfg.workTypeName;
        sa.Admission_Counselor__c = assignment.userId;
        if (String.isNotBlank(clientTimezone)) sa.TimeZone = normalizeTimezone(clientTimezone);
        try {
            Object g = leadRebook.get('Student_Grade__c');
            if (g != null) sa.Student_Grade__c = String.valueOf(g);
        } catch (Exception ignored) { }
        sa.Reschedule_Token__c = RescheduleTokenService.generateToken();
        String custName = ((leadRebook.FirstName == null ? '' : leadRebook.FirstName)
                         + ' '
                         + (leadRebook.LastName == null ? '' : leadRebook.LastName)).trim();
        if (String.isNotBlank(custName)) {
            tryPut(sa, 'Customer_Name__c', custName);
        }
        tryPut(sa, 'Lead__c', leadRebook.Id);
        tryPut(sa, 'Landing_Page_Source__c', landingPageSource);
        insert sa;

        AssignedResource ar = new AssignedResource();
        ar.ServiceAppointmentId = sa.Id;
        ar.ServiceResourceId = assignment.resourceId;
        insert ar;

        try {
            Lead leadUpdate = new Lead(Id = leadRebook.Id);
            leadUpdate.Status = 'IC Scheduled';
            try { leadUpdate.put('IC_Meeting_Rescheduled__c', true); } catch (Exception ignored) { }
            try { leadUpdate.put('IC_Reschedule_Token__c', null); } catch (Exception ignored) { }
            try {
                leadUpdate.put('Scheduled_Meeting_DateTime__c', startDT);
            } catch (Exception ignored) { }
            try {
                if (res.containsKey('appointmentId')) {
                    leadUpdate.put('Service_Appointment__c', sa.Id);
                }
            } catch (Exception ignored) { }
            update leadUpdate;
        } catch (Exception ex) { }

        res.put('success', 'true');
        res.put('appointmentId', sa.Id);
        res.put('leadId', leadRebook.Id);
        stampActionUrls(res, sa.Reschedule_Token__c);
    }

    // First-time IC schedule against an existing Lead via the IC_Schedule_Token__c (single-use).
    private static void bookICFromScheduleToken(
        Map<String, String> res, DiscoveredConfig cfg, ResourceAssignment assignment,
        Lead leadSched, DateTime startDT, DateTime endDT, String clientTimezone,
        String landingPageSource
    ) {
        Id saTerritoryId = (assignment.territoryId != null)
            ? assignment.territoryId : cfg.serviceTerritoryId;
        DateTime saEndDT = startDT.addMinutes(60);

        ServiceAppointment sa = new ServiceAppointment();
        sa.ParentRecordId = leadSched.Id;
        sa.ServiceTerritoryId = saTerritoryId;
        sa.WorkTypeId = cfg.workTypeId;
        sa.EarliestStartTime = startDT;
        sa.DueDate = saEndDT;
        sa.SchedStartTime = startDT;
        sa.SchedEndTime = saEndDT;
        sa.ArrivalWindowStartTime = startDT;
        sa.ArrivalWindowEndTime = saEndDT;
        sa.DurationType = cfg.durationType;
        sa.AppointmentType = cfg.appointmentType;
        sa.Status = 'Scheduled';
        sa.Subject = SUBJECT_MAP.get('IC');
        sa.Street = cfg.street;
        sa.City = cfg.city;
        sa.State = cfg.state;
        sa.Phone = leadSched.Phone;
        sa.Email = leadSched.Email;
        sa.Meeting_Type__c = MEETING_TYPE_MAP.get('IC');
        sa.AdditionalInformation = cfg.workTypeName;
        sa.Admission_Counselor__c = assignment.userId;
        if (String.isNotBlank(clientTimezone)) sa.TimeZone = normalizeTimezone(clientTimezone);
        try {
            Object g = leadSched.get('Student_Grade__c');
            if (g != null) sa.Student_Grade__c = String.valueOf(g);
        } catch (Exception ignored) { }
        sa.Reschedule_Token__c = RescheduleTokenService.generateToken();
        String custName = ((leadSched.FirstName == null ? '' : leadSched.FirstName)
                         + ' '
                         + (leadSched.LastName == null ? '' : leadSched.LastName)).trim();
        if (String.isNotBlank(custName)) {
            tryPut(sa, 'Customer_Name__c', custName);
        }
        tryPut(sa, 'Lead__c', leadSched.Id);
        tryPut(sa, 'Landing_Page_Source__c', landingPageSource);
        insert sa;

        AssignedResource ar = new AssignedResource();
        ar.ServiceAppointmentId = sa.Id;
        ar.ServiceResourceId = assignment.resourceId;
        insert ar;

        try {
            Lead leadUpdate = new Lead(Id = leadSched.Id);
            leadUpdate.OwnerId = assignment.userId;
            try { leadUpdate.put('Assigned_Admission_Counsellor__c', assignment.userId); } catch (Exception ignored) { }
            leadUpdate.Status = 'IC Scheduled';
            try { leadUpdate.put('Meeting_Status__c', 'Scheduled'); } catch (Exception ignored) { }
            try { leadUpdate.put('IC_Schedule_Token__c', null); } catch (Exception ignored) { }
            try { leadUpdate.put('IC_Schedule_Link__c', null); } catch (Exception ignored) { }
            try { leadUpdate.put('Scheduled_Meeting_DateTime__c', startDT); } catch (Exception ignored) { }
            try { leadUpdate.put('Service_Appointment__c', sa.Id); } catch (Exception ignored) { }
            update leadUpdate;
        } catch (Exception ex) { }

        res.put('success', 'true');
        res.put('appointmentId', sa.Id);
        res.put('leadId', leadSched.Id);
        stampActionUrls(res, sa.Reschedule_Token__c);
    }

    // First-time IC booking from the public LWC form: create Lead + Event + SA + AssignedResource.
    private static void bookIC(
        Map<String, String> res, DiscoveredConfig cfg, ResourceAssignment assignment,
        DateTime startDT, DateTime endDT,
        String firstName, String lastName, String email, String phone,
        String studentGrade, String leadSource, String guestEmails,
        String clientTimezone, String utmSource, String utmCampaign, String utmMedium,
        String utmAd, String utmAdSet, String notes,
        String landingPageSource
    ) {
        String cleanEmail = email.trim().toLowerCase();
        String cleanFirst = firstName.trim();
        String cleanLast = lastName.trim();
        String cleanPhone = phone.trim();
        Database.DMLOptions dmlOpts = dmlAllowDupes();
        List<String> guestList = parseGuestEmails(guestEmails);

        Lead mktLead = new Lead(
            FirstName = cleanFirst, LastName = cleanLast, Email = cleanEmail,
            Phone = cleanPhone, LeadSource = leadSource,
            Status = 'IC Scheduled', Meeting_Status__c = 'Scheduled',
            Assigned_Admission_Counsellor__c = assignment.userId,
            OwnerId = assignment.userId);
        tryPut(mktLead, 'Student_Grade__c', studentGrade);
        tryPut(mktLead, 'UTM_Source__c', utmSource);
        tryPut(mktLead, 'UTM_Campaign__c', utmCampaign);
        tryPut(mktLead, 'UTM_Medium__c', utmMedium);
        tryPut(mktLead, 'UTM_Ad__c', utmAd);
        tryPut(mktLead, 'UTM_AdSet__c', utmAdSet);
        if (guestList != null && !guestList.isEmpty()) {
            tryPut(mktLead, 'Guest_Emails__c', String.join(guestList, ','));
        }
        mktLead.Description = buildLeadDescription(notes, studentGrade, guestList);
        mktLead.setOptions(dmlOpts);
        Database.SaveResult leadSr = Database.insert(mktLead, dmlOpts);
        if (!leadSr.isSuccess()) {
            String err = '';
            for (Database.Error e : leadSr.getErrors()) err += e.getMessage() + ' ';
            throw new AuraHandledException('Lead creation failed: ' + err);
        }

        Event booking = new Event();
        booking.Subject = SUBJECT_MAP.get('IC');
        booking.StartDateTime = startDT;
        booking.EndDateTime = startDT.addMinutes(60);
        booking.ShowAs = 'Busy';
        booking.Type = 'Meeting';
        booking.DurationInMinutes = 60;
        booking.IsAllDayEvent = false;
        booking.IsPrivate = false;
        booking.WhoId = mktLead.Id;
        if (assignment.userId != null) booking.OwnerId = assignment.userId;
        booking.Location = 'Zoom';
        booking.Description = buildEventDescription(notes, guestList);
        insert booking;

        res.put('leadId', mktLead.Id);
        res.put('eventId', booking.Id);
        res.put('success', 'true');

        try {
            Id saTerritoryId = (assignment.territoryId != null)
                ? assignment.territoryId : cfg.serviceTerritoryId;
            ServiceAppointment sa = new ServiceAppointment();
            sa.ParentRecordId = mktLead.Id;
            sa.ServiceTerritoryId = saTerritoryId;
            sa.WorkTypeId = cfg.workTypeId;
            DateTime saEndDT = startDT.addMinutes(60);
            sa.EarliestStartTime = startDT;
            sa.DueDate = saEndDT;
            sa.SchedStartTime = startDT;
            sa.SchedEndTime = saEndDT;
            sa.ArrivalWindowStartTime = startDT;
            sa.ArrivalWindowEndTime = saEndDT;
            sa.DurationType = cfg.durationType;
            sa.AppointmentType = cfg.appointmentType;
            sa.Status = 'Scheduled';
            sa.Subject = SUBJECT_MAP.get('IC');
            sa.Street = cfg.street;
            sa.City = cfg.city;
            sa.State = cfg.state;
            sa.Phone = cleanPhone;
            sa.Email = cleanEmail;
            sa.Meeting_Type__c = MEETING_TYPE_MAP.get('IC');
            sa.AdditionalInformation = cfg.workTypeName;
            sa.Admission_Counselor__c = assignment.userId;
            if (String.isNotBlank(clientTimezone)) sa.TimeZone = normalizeTimezone(clientTimezone);
            sa.Student_Grade__c = studentGrade;
            sa.Reschedule_Token__c = RescheduleTokenService.generateToken();
            tryPut(sa, 'Customer_Name__c', cleanFirst + ' ' + cleanLast);
            tryPut(sa, 'Lead__c', mktLead.Id);
            tryPut(sa, 'Landing_Page_Source__c', landingPageSource);
            insert sa;

            AssignedResource ar = new AssignedResource();
            ar.ServiceAppointmentId = sa.Id;
            ar.ServiceResourceId = assignment.resourceId;
            insert ar;

            res.put('appointmentId', sa.Id);
            stampActionUrls(res, sa.Reschedule_Token__c);
            try {
                tryPut(booking, 'Service_Appointment__c', sa.Id);
                booking.Description += '\nAppointment: ' + sa.Id;
                update booking;
            } catch (Exception ue) { }
        } catch (Exception saEx) { }

        try {
            Lead upd = new Lead(Id = mktLead.Id);
            tryPut(upd, 'Scheduled_Meeting_DateTime__c', startDT);
            if (res.containsKey('appointmentId'))
                tryPut(upd, 'Service_Appointment__c', res.get('appointmentId'));
            update upd;
        } catch (Exception ex) { }

        try {
            sendGuestInvitations(guestList, startDT, endDT, cleanFirst, cleanLast,
                                 cleanEmail, clientTimezone);
        } catch (Exception emailEx) { }
    }

    // PD / FSS booking against an Opportunity / Contact (sticky resource + stage flips).
    private static void bookPDorFSS(
        Map<String, String> res, DiscoveredConfig cfg, ResourceAssignment assignment,
        String bType, DateTime startDT, DateTime endDT,
        String contactId, String opportunityId, String clientTimezone,
        String guestEmails, String notes, String landingPageSource
    ) {
        List<String> guestList = parseGuestEmails(guestEmails);
        String meetingType = MEETING_TYPE_MAP.get(bType);
        String subject = SUBJECT_MAP.get(bType);
        Integer duration = cfg.durationMinutes;

        Id accountId = null;
        Id conId = null;
        if (String.isNotBlank(contactId)) {
            conId = (Id) contactId;
            List<Contact> contacts = [SELECT AccountId FROM Contact WHERE Id = :conId LIMIT 1];
            if (!contacts.isEmpty()) accountId = contacts[0].AccountId;
        }

        Id saTerritoryId = null;
        for (ServiceTerritoryMember stm : [
            SELECT ServiceTerritoryId FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :assignment.resourceId
            AND ServiceTerritory.IsActive = true
            AND TerritoryType = 'P'
            AND EffectiveStartDate <= :Date.today()
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :Date.today())
            ORDER BY CreatedDate ASC LIMIT 1
        ]) {
            saTerritoryId = stm.ServiceTerritoryId;
        }
        if (saTerritoryId == null) {
            for (ServiceTerritoryMember stm : [
                SELECT ServiceTerritoryId FROM ServiceTerritoryMember
                WHERE ServiceResourceId = :assignment.resourceId
                AND ServiceTerritory.IsActive = true
                AND EffectiveStartDate <= :Date.today()
                AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :Date.today())
                ORDER BY CreatedDate ASC LIMIT 1
            ]) {
                saTerritoryId = stm.ServiceTerritoryId;
            }
        }
        if (saTerritoryId == null) {
            saTerritoryId = (assignment.territoryId != null) ? assignment.territoryId : cfg.serviceTerritoryId;
        }

        ServiceAppointment sa = new ServiceAppointment();
        sa.ParentRecordId = accountId;
        sa.ContactId = conId;
        sa.ServiceTerritoryId = saTerritoryId;
        sa.WorkTypeId = cfg.workTypeId;
        sa.SchedStartTime = startDT;
        sa.SchedEndTime = endDT;
        sa.EarliestStartTime = startDT;
        sa.DueDate = endDT;
        sa.ArrivalWindowStartTime = startDT;
        sa.ArrivalWindowEndTime = endDT;
        sa.DurationType = cfg.durationType;
        sa.AppointmentType = cfg.appointmentType;
        sa.Status = 'Scheduled';
        sa.Subject = subject;
        sa.Meeting_Type__c = meetingType;
        sa.OwnerId = assignment.userId;
        sa.Street = cfg.street;
        sa.City = cfg.city;
        sa.State = cfg.state;
        if (String.isNotBlank(clientTimezone)) sa.TimeZone = normalizeTimezone(clientTimezone);
        if (bType == 'PD') {
            tryPut(sa, 'Program_Director__c', assignment.userId);
        }
        if (bType == 'FSS') {
            tryPut(sa, 'Family_Success_Specialist__c', assignment.userId);
        }
        if (String.isBlank(opportunityId) && conId != null) {
            try {
                List<OpportunityContactRole> ocrs = [
                    SELECT OpportunityId FROM OpportunityContactRole
                    WHERE ContactId = :conId AND Opportunity.IsClosed = false
                    ORDER BY CreatedDate DESC LIMIT 1
                ];
                if (!ocrs.isEmpty()) opportunityId = ocrs[0].OpportunityId;
            } catch (Exception ex) { }
        }
        if (String.isNotBlank(opportunityId)) tryPut(sa, 'Opportunity__c', (Id) opportunityId);
        sa.Reschedule_Token__c = RescheduleTokenService.generateToken();
        if (conId != null) {
            for (Contact con : [SELECT Name FROM Contact WHERE Id = :conId LIMIT 1]) {
                tryPut(sa, 'Customer_Name__c', con.Name);
            }
        }
        String saDesc = buildEventDescription(notes, guestList);
        if (String.isNotBlank(saDesc)) sa.Description = saDesc;
        tryPut(sa, 'Landing_Page_Source__c', landingPageSource);
        insert sa;

        try {
            ServiceAppointment mtFix = new ServiceAppointment(Id = sa.Id);
            mtFix.Meeting_Type__c = meetingType;
            update mtFix;
        } catch (Exception mtEx) {
            System.debug(LoggingLevel.WARN,
                'Meeting_Type__c re-stamp failed for SA ' + sa.Id + ': ' + mtEx.getMessage());
        }

        AssignedResource ar = new AssignedResource();
        ar.ServiceAppointmentId = sa.Id;
        ar.ServiceResourceId = assignment.resourceId;
        insert ar;

        try {
            Event evt = new Event();
            evt.Subject = subject;
            evt.StartDateTime = startDT;
            evt.EndDateTime = endDT;
            evt.OwnerId = assignment.userId;
            evt.ShowAs = 'Busy';
            evt.Location = 'Zoom';
            if (conId != null) evt.WhoId = conId;
            if (String.isNotBlank(opportunityId)) evt.WhatId = (Id) opportunityId;
            tryPut(evt, 'Service_Appointment__c', sa.Id);
            String evtDesc = buildEventDescription(notes, guestList);
            if (String.isNotBlank(evtDesc)) evt.Description = evtDesc;
            insert evt;
        } catch (Exception evtEx) { }

        try {
            ServiceResource pdSr = [SELECT Appointment_Count__c FROM ServiceResource WHERE Id = :assignment.resourceId LIMIT 1];
            pdSr.Appointment_Count__c = (pdSr.Appointment_Count__c != null) ? pdSr.Appointment_Count__c + 1 : 1;
            update pdSr;
        } catch (Exception srEx) { }

        if (bType == 'PD' && String.isNotBlank(opportunityId)) {
            try {
                Opportunity opp = [
                    SELECT Id, Program_Director__c, StageName
                    FROM Opportunity WHERE Id = :opportunityId LIMIT 1
                ];
                Boolean changed = false;
                if (opp.Program_Director__c == null) {
                    opp.Program_Director__c = assignment.userId;
                    changed = true;
                }
                if (opp.StageName != 'SOM Scheduled'
                        && opp.StageName != 'Closed Won'
                        && opp.StageName != 'Closed Lost') {
                    opp.StageName = 'SOM Scheduled';
                    changed = true;
                }
                if (changed) update opp;
            } catch (Exception ex) {
                System.debug(LoggingLevel.WARN,
                    'PD booking stage flip failed for opp=' + opportunityId
                    + ': ' + ex.getMessage());
            }
            stampStudentContact((Id) opportunityId, 'Program_Director__c', assignment.userId);
            stampStudentContact((Id) opportunityId, 'Stage__c', 'SOM Scheduled');
        }

        if (bType == 'FSS' && String.isNotBlank(opportunityId)) {
            try {
                Opportunity opp = [SELECT Id, Family_Success_Specialist__c FROM Opportunity WHERE Id = :opportunityId LIMIT 1];
                if (opp.Family_Success_Specialist__c == null) { opp.Family_Success_Specialist__c = assignment.userId; update opp; }
            } catch (Exception ex) { }
            stampStudentContact((Id) opportunityId, 'Family_Success_Specialist__c', assignment.userId);
        }

        if (isOneTimeUseType(bType) && String.isNotBlank(opportunityId)) {
            try {
                Opportunity stamp = new Opportunity(Id = (Id) opportunityId);
                if (bType == 'PD')  stamp.PD_Link_Used_At__c  = System.now();
                if (bType == 'FSS') stamp.FSS_Link_Used_At__c = System.now();
                update stamp;
            } catch (Exception stampEx) { }
        }

        User assignedUser = [SELECT Name FROM User WHERE Id = :assignment.userId LIMIT 1];
        res.put('success', 'true');
        res.put('appointmentId', sa.Id);
        res.put('assignedTo', assignedUser.Name);
        res.put('meetingType', meetingType);
        stampActionUrls(res, sa.Reschedule_Token__c);
    }

    // PD/FSS bookings are single-use; IC is not.
    private static Boolean isOneTimeUseType(String bType) {
        return bType == 'PD' || bType == 'FSS';
    }

    // Resolved at class-load time from the org's My Domain URL.
    private static final String BOOKING_BASE_URL =
        URL.getOrgDomainUrl().toExternalForm() + '/s/booking';

    // Add reschedule + cancel URLs (driven by the SA's reschedule token) into the result map.
    private static void stampActionUrls(Map<String, String> res, String token) {
        if (String.isBlank(token)) return;
        res.put('rescheduleUrl', BOOKING_BASE_URL + '?token=' + token + '&action=reschedule');
        res.put('cancelUrl',     BOOKING_BASE_URL + '?token=' + token + '&action=cancel');
    }

    // Returns true when the PD/FSS one-time-use link has already been consumed for this Opp.
    private static Boolean isLinkAlreadyUsed(String opportunityId, String bType) {
        try {
            String fld = (bType == 'PD') ? 'PD_Link_Used_At__c' : 'FSS_Link_Used_At__c';
            List<Opportunity> opps = Database.query(
                'SELECT ' + fld + ' FROM Opportunity WHERE Id = :opportunityId LIMIT 1');
            return !opps.isEmpty() && opps[0].get(fld) != null;
        } catch (Exception e) {
            return false;
        }
    }

    // Same as isLinkAlreadyUsed but acquires a row lock for the booking transaction.
    private static Boolean isLinkAlreadyUsedForUpdate(String opportunityId, String bType) {
        try {
            String fld = (bType == 'PD') ? 'PD_Link_Used_At__c' : 'FSS_Link_Used_At__c';
            List<Opportunity> opps = Database.query(
                'SELECT Id, ' + fld + ' FROM Opportunity WHERE Id = :opportunityId LIMIT 1 FOR UPDATE');
            return !opps.isEmpty() && opps[0].get(fld) != null;
        } catch (Exception e) {
            return false;
        }
    }

    // Pick the next available resource (sticky on reschedule / PD opportunity, else round-robin).
    private static ResourceAssignment findAvailableResourceRoundRobin(
        DiscoveredConfig cfg, DateTime startDT, DateTime endDT, String bType, String opportunityId,
        String rescheduleToken
    ) {
        if (String.isNotBlank(rescheduleToken)) {
            Id stickyResId = findStickyResourceForReschedule(rescheduleToken);
            if (stickyResId != null) {
                ResourceAssignment ra = new ResourceAssignment();
                ra.resourceId = stickyResId;
                List<ServiceResource> srs = [
                    SELECT Id, RelatedRecordId FROM ServiceResource
                    WHERE Id = :stickyResId AND IsActive = true LIMIT 1
                ];
                if (!srs.isEmpty()) {
                    ra.userId = srs[0].RelatedRecordId;
                    for (ServiceTerritoryMember stm : [
                        SELECT ServiceTerritoryId FROM ServiceTerritoryMember
                        WHERE ServiceResourceId = :stickyResId
                        AND ServiceTerritory.IsActive = true
                        AND EffectiveStartDate <= :Date.today()
                        AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :Date.today())
                        ORDER BY CreatedDate DESC LIMIT 1
                    ]) { ra.territoryId = stm.ServiceTerritoryId; }
                    return ra;
                }
            }
        }

        if (bType == 'PD' && String.isNotBlank(opportunityId)) {
            List<Opportunity> opps = [SELECT Program_Director__c FROM Opportunity WHERE Id = :opportunityId LIMIT 1];
            if (!opps.isEmpty() && opps[0].Program_Director__c != null) {
                List<ServiceResource> srs = [
                    SELECT Id FROM ServiceResource
                    WHERE RelatedRecordId = :opps[0].Program_Director__c AND IsActive = true LIMIT 1
                ];
                if (!srs.isEmpty()) {
                    ResourceAssignment stickyRA = new ResourceAssignment();
                    stickyRA.resourceId = srs[0].Id;
                    stickyRA.userId = opps[0].Program_Director__c;
                    for (ServiceTerritoryMember stm : [
                        SELECT ServiceTerritoryId FROM ServiceTerritoryMember
                        WHERE ServiceResourceId = :srs[0].Id AND ServiceTerritory.IsActive = true
                        ORDER BY CreatedDate DESC LIMIT 1
                    ]) { stickyRA.territoryId = stm.ServiceTerritoryId; }
                    return stickyRA;
                }
            }
        }

        Date today = Date.today();
        Date scanEnd = today.addDays(cfg.timeframeEndDays - 1);
        ResourceBundle rb = loadResources(cfg.allTerritoryIds, today, scanEnd, bType);
        if (rb.resourceIds.isEmpty()) return null;

        Map<Id, List<List<DateTime>>> rawBusy =
            buildRawBusyMap(rb, cfg.allTerritoryIds, startDT.addHours(-2), endDT.addHours(2));

        List<Id> freeRes = new List<Id>();
        for (Id rId : rb.orderedResourceIds) {
            List<List<DateTime>> ivs = rawBusy.get(rId);
            Boolean free = true;
            if (ivs != null) {
                for (List<DateTime> iv : ivs) {
                    if (startDT < iv[1] && endDT > iv[0]) { free = false; break; }
                }
            }
            if (free && rb.resourceToUserId.containsKey(rId)) freeRes.add(rId);
        }
        if (freeRes.isEmpty()) return null;

        Map<Id,Id> userToRes = new Map<Id,Id>();
        Map<Id,Integer> counts = new Map<Id,Integer>();
        for (Id rId : freeRes) {
            counts.put(rId, 0);
            Id uId = rb.resourceToUserId.get(rId);
            if (uId != null) userToRes.put(uId, rId);
        }
        if (!userToRes.isEmpty()) {
            for (AggregateResult ag : [
                SELECT OwnerId, COUNT(Id) cnt FROM Event
                WHERE OwnerId IN :userToRes.keySet()
                AND StartDateTime >= :today
                GROUP BY OwnerId
            ]) {
                Id uId = (Id)ag.get('OwnerId');
                Id rId = userToRes.get(uId);
                if (rId != null && counts.containsKey(rId))
                    counts.put(rId, (Integer)ag.get('cnt'));
            }
        }

        Id bestId = null;
        Integer minC = 2147483647;
        for (Id rId : freeRes) {
            Integer c = counts.get(rId);
            if (c < minC) { minC = c; bestId = rId; }
        }
        if (bestId != null) {
            ResourceAssignment ra = new ResourceAssignment();
            ra.resourceId = bestId;
            ra.userId = rb.resourceToUserId.get(bestId);
            ra.territoryId = rb.resourceToTerritoryId.get(bestId);
            return ra;
        }
        return null;
    }

    // Generate the candidate slots (UTC) for one local date that pass the operating-hours window.
    private static List<SlotInfo> generateSlotsForDate(
        Date d, Integer duration, Integer slotInterval, Integer timeframeStartDays,
        Map<String, List<TimeSlot>> slotsByDay, ResourceBundle rb,
        Map<Id, List<List<DateTime>>> rawBusy, TimeZone tz, String tzId
    ) {
        List<SlotInfo> out = new List<SlotInfo>();
        Date today = Date.today();
        if (timeframeStartDays > 0 && d < today.addDays(timeframeStartDays)) return out;

        DateTime noonGmt = DateTime.newInstanceGmt(d, Time.newInstance(12,0,0,0));
        String dayName = noonGmt.format('EEEE', tzId);
        List<TimeSlot> windows = slotsByDay.get(dayName);
        if (windows == null || windows.isEmpty()) return out;

        Integer interval = (slotInterval != null && slotInterval >= 15) ? slotInterval : 30;
        Integer nowLocal = utcToLocalMinutes(DateTime.now(), d, tz);
        Integer minStart = (d == today) ? nowLocal + (DEFAULT_ADVANCE_HOURS * 60) : 0;
        DateTime dayStartUtc = localToUtc(d, 0, tz);
        DateTime dayEndUtc = localToUtc(d.addDays(1), 0, tz);

        Map<Id, List<List<Integer>>> busyMap = new Map<Id, List<List<Integer>>>();
        for (Id rId : rb.resourceIds) {
            busyMap.put(rId, new List<List<Integer>>());
            List<List<DateTime>> raw = rawBusy.get(rId);
            if (raw == null) continue;
            for (List<DateTime> iv : raw) {
                if (iv[0] < dayEndUtc && iv[1] > dayStartUtc) {
                    busyMap.get(rId).add(new List<Integer>{
                        utcToLocalMinutes(iv[0], d, tz), utcToLocalMinutes(iv[1], d, tz)
                    });
                }
            }
        }

        for (TimeSlot tw : windows) {
            Integer ws = tw.StartTime.hour()*60 + tw.StartTime.minute();
            Integer we = tw.EndTime.hour()*60 + tw.EndTime.minute();
            Integer ss = ws;
            while (ss + duration <= we) {
                if (ss >= minStart && isAnyResourceFree(rb.resourceIds, ss, ss+duration, busyMap)) {
                    SlotInfo si = new SlotInfo();
                    si.startUtc = localToUtc(d, ss, tz);
                    si.endUtc = localToUtc(d, ss+duration, tz);
                    out.add(si);
                }
                ss += interval;
            }
        }
        return out;
    }

    // Return the list of dates in the scan window that have at least one free slot.
    private static List<String> computeAvailableDates(DiscoveredConfig cfg, Integer targetDays) {
        List<String> out = new List<String>();
        Integer dur = cfg.durationMinutes;
        Integer interval = cfg.slotIntervalMinutes;
        Integer scanDays = cfg.timeframeEndDays;
        String tzId = cfg.territoryTimezone;
        TimeZone tz = TimeZone.getTimeZone(tzId);
        Date today = Date.today();
        Date scanEnd = today.addDays(scanDays - 1);

        Map<String, List<TimeSlot>> slotsByDay = loadOperatingHours(cfg.operatingHoursId);
        if (slotsByDay.isEmpty()) return out;

        ResourceBundle rb = loadResources(cfg.allTerritoryIds, today, scanEnd, cfg.bookingType);
        if (rb.resourceIds.isEmpty()) return out;

        DateTime scanStartUtc = localToUtc(today, 0, tz).addHours(-2);
        DateTime scanEndUtc = localToUtc(scanEnd.addDays(1), 0, tz).addHours(2);

        Map<Id, List<List<DateTime>>> rawBusy =
            buildRawBusyMap(rb, cfg.allTerritoryIds, scanStartUtc, scanEndUtc);

        for (Integer i = 0; i < scanDays && out.size() < targetDays; i++) {
            Date d = today.addDays(i);
            List<SlotInfo> slots = generateSlotsForDate(
                d, dur, interval, cfg.timeframeStartDays, slotsByDay, rb, rawBusy, tz, tzId);
            Boolean hasAvail = false;
            for (SlotInfo si : slots) {
                if (countFreeResources(rb, rawBusy, si.startUtc, si.endUtc) > 0) { hasAvail = true; break; }
            }
            if (hasAvail) out.add(toDateStr(d));
        }
        return out;
    }

    // Load OperatingHours TimeSlots grouped by day-of-week.
    private static Map<String, List<TimeSlot>> loadOperatingHours(Id opHoursId) {
        Map<String, List<TimeSlot>> m = new Map<String, List<TimeSlot>>();
        for (TimeSlot ts : [
            SELECT DayOfWeek, StartTime, EndTime FROM TimeSlot
            WHERE OperatingHoursId = :opHoursId ORDER BY StartTime ASC
        ]) {
            if (!m.containsKey(ts.DayOfWeek)) m.put(ts.DayOfWeek, new List<TimeSlot>());
            m.get(ts.DayOfWeek).add(ts);
        }
        return m;
    }

    // Load the active resources (filtered by profile) and their territory + user mappings.
    private static ResourceBundle loadResources(
        Set<Id> territoryIds, Date rangeStart, Date rangeEnd, String bType
    ) {
        ResourceBundle rb = new ResourceBundle();
        Map<Id,Id> bestTerritory = new Map<Id,Id>();
        Set<Id> candidates = new Set<Id>();

        for (ServiceTerritoryMember m : [
            SELECT ServiceResourceId, ServiceTerritoryId
            FROM ServiceTerritoryMember
            WHERE ServiceTerritoryId IN :territoryIds
            AND EffectiveStartDate <= :rangeEnd
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :rangeStart)
            AND ServiceResource.IsActive = true
            ORDER BY CreatedDate DESC
        ]) {
            candidates.add(m.ServiceResourceId);
            if (!bestTerritory.containsKey(m.ServiceResourceId)) {
                bestTerritory.put(m.ServiceResourceId, m.ServiceTerritoryId);
            }
        }
        if (candidates.isEmpty()) return rb;

        Map<Id,Id> srToUser = new Map<Id,Id>();
        for (ServiceResource sr : [
            SELECT Id, RelatedRecordId FROM ServiceResource
            WHERE Id IN :candidates AND IsActive = true
        ]) {
            if (sr.RelatedRecordId != null && String.valueOf(sr.RelatedRecordId).startsWith('005')) {
                srToUser.put(sr.Id, sr.RelatedRecordId);
            }
        }
        if (srToUser.isEmpty()) return rb;

        List<String> profileNames = getProfileNames(bType);
        Set<Id> validUsers = new Set<Id>();
        if (profileNames.size() == 1) {
            String pName = profileNames[0];
            for (User u : [SELECT Id FROM User WHERE Id IN :srToUser.values() AND Profile.Name = :pName AND IsActive = true]) {
                validUsers.add(u.Id);
            }
        } else {
            String p1 = profileNames[0];
            String p2 = profileNames[1];
            for (User u : [SELECT Id FROM User WHERE Id IN :srToUser.values() AND (Profile.Name = :p1 OR Profile.Name = :p2) AND IsActive = true]) {
                validUsers.add(u.Id);
            }
        }

        for (Id srId : srToUser.keySet()) {
            if (validUsers.contains(srToUser.get(srId))) {
                rb.resourceIds.add(srId);
                rb.orderedResourceIds.add(srId);
                rb.resourceToUserId.put(srId, srToUser.get(srId));
                rb.resourceToTerritoryId.put(srId, bestTerritory.get(srId));
            }
        }
        return rb;
    }

    // Build the per-resource busy map from existing SAs, Events, and ResourceAbsences.
    private static Map<Id, List<List<DateTime>>> buildRawBusyMap(
        ResourceBundle rb, Set<Id> territoryIds, DateTime rangeStart, DateTime rangeEnd
    ) {
        Map<Id, List<List<DateTime>>> busy = new Map<Id, List<List<DateTime>>>();
        for (Id rId : rb.resourceIds) busy.put(rId, new List<List<DateTime>>());

        List<ServiceAppointment> appts = [
            SELECT Id, SchedStartTime, SchedEndTime FROM ServiceAppointment
            WHERE ServiceTerritoryId IN :territoryIds
            AND SchedStartTime < :rangeEnd AND SchedEndTime > :rangeStart
            AND Status NOT IN ('Canceled','Cannot Complete')
        ];
        if (!appts.isEmpty()) {
            Map<Id,ServiceAppointment> saMap = new Map<Id,ServiceAppointment>(appts);
            for (AssignedResource arRec : [
                SELECT ServiceAppointmentId, ServiceResourceId FROM AssignedResource
                WHERE ServiceAppointmentId IN :saMap.keySet()
                AND ServiceResourceId IN :rb.resourceIds
            ]) {
                ServiceAppointment sa = saMap.get(arRec.ServiceAppointmentId);
                if (sa != null && busy.containsKey(arRec.ServiceResourceId)) {
                    busy.get(arRec.ServiceResourceId).add(
                        new List<DateTime>{sa.SchedStartTime, sa.SchedEndTime});
                }
            }
        }

        if (!rb.resourceToUserId.isEmpty()) {
            Set<Id> uIds = new Set<Id>(rb.resourceToUserId.values());
            Map<Id,Id> uToR = new Map<Id,Id>();
            for (Id rId : rb.resourceToUserId.keySet()) {
                uToR.put(rb.resourceToUserId.get(rId), rId);
            }
            for (Event ev : [
                SELECT OwnerId, StartDateTime, EndDateTime FROM Event
                WHERE OwnerId IN :uIds
                AND StartDateTime < :rangeEnd AND EndDateTime > :rangeStart
                AND (ShowAs = NULL OR ShowAs != 'Free')
            ]) {
                Id rId = uToR.get(ev.OwnerId);
                if (rId != null && busy.containsKey(rId)) {
                    busy.get(rId).add(new List<DateTime>{ev.StartDateTime, ev.EndDateTime});
                }
            }
        }

        for (ResourceAbsence ra : [
            SELECT ResourceId, Start, End FROM ResourceAbsence
            WHERE ResourceId IN :rb.resourceIds
            AND Start < :rangeEnd AND End > :rangeStart
        ]) {
            if (busy.containsKey(ra.ResourceId)) {
                busy.get(ra.ResourceId).add(new List<DateTime>{ra.Start, ra.End});
            }
        }
        return busy;
    }

    // Returns true if at least one resource has no overlap in the local-minute window.
    private static Boolean isAnyResourceFree(
        Set<Id> rIds, Integer ss, Integer se, Map<Id, List<List<Integer>>> busyMap
    ) {
        for (Id rId : rIds) {
            List<List<Integer>> b = busyMap.get(rId);
            if (b == null || b.isEmpty()) return true;
            Boolean free = true;
            for (List<Integer> iv : b) {
                if (ss < iv[1] && se > iv[0]) { free = false; break; }
            }
            if (free) return true;
        }
        return false;
    }

    // Convert a local date + minutes-offset into an absolute UTC DateTime for the given timezone.
    private static DateTime localToUtc(Date d, Integer mins, TimeZone tz) {
        if (mins >= 1440) { d = d.addDays(mins / 1440); mins = Math.mod(mins, 1440); }
        DateTime g = DateTime.newInstanceGmt(d, Time.newInstance(mins/60, Math.mod(mins,60), 0, 0));
        return g.addSeconds(-(tz.getOffset(g) / 1000));
    }

    // Convert a UTC DateTime into local minutes-of-day for a given timezone.
    private static Integer utcToLocalMinutes(DateTime utcDT, Date ref, TimeZone tz) {
        DateTime loc = utcDT.addSeconds(tz.getOffset(utcDT) / 1000);
        String hm = loc.formatGmt('HH:mm');
        List<String> p = hm.split(':');
        return Integer.valueOf(p[0]) * 60 + Integer.valueOf(p[1]);
    }

    private static final Map<String, String> TZ_ALIASES = new Map<String, String>{
        'Asia/Calcutta'       => 'Asia/Kolkata',
        'Asia/Saigon'         => 'Asia/Ho_Chi_Minh',
        'Asia/Katmandu'       => 'Asia/Kathmandu',
        'Asia/Rangoon'        => 'Asia/Yangon',
        'Pacific/Ponape'      => 'Pacific/Pohnpei',
        'Pacific/Truk'        => 'Pacific/Chuuk',
        'Atlantic/Faeroe'     => 'Atlantic/Faroe',
        'Europe/Kiev'         => 'Europe/Kyiv',
        'America/Buenos_Aires'=> 'America/Argentina/Buenos_Aires'
    };

    // Map browser-provided legacy TZ ids to their canonical equivalents.
    private static String normalizeTimezone(String tz) {
        return TZ_ALIASES.containsKey(tz) ? TZ_ALIASES.get(tz) : tz;
    }

    // Parse an ISO-8601 string (Z-suffixed) into a UTC DateTime.
    private static DateTime parseISO(String iso) {
        return DateTime.valueOfGmt(iso.replace('T',' ').replace('Z',''));
    }

    // Format a Date as 'YYYY-MM-DD'.
    private static String toDateStr(Date d) {
        return String.valueOf(d.year()) + '-' + String.valueOf(d.month()).leftPad(2,'0')
            + '-' + String.valueOf(d.day()).leftPad(2,'0');
    }

    // Best-effort SObject.put — swallows missing-field / FLS errors.
    private static void tryPut(SObject rec, String f, Object v) {
        try { rec.put(f, v); } catch (Exception ex) { }
    }

    // Mirror an Opportunity-level value onto the Student-role OCR's Contact (best-effort).
    private static void stampStudentContact(Id opportunityId, String contactFieldName, Object newValue) {
        if (opportunityId == null || newValue == null || String.isBlank(contactFieldName)) return;
        try {
            List<OpportunityContactRole> ocrs = [
                SELECT ContactId
                FROM OpportunityContactRole
                WHERE OpportunityId = :opportunityId
                  AND Role = 'Student'
                  AND ContactId != null
                ORDER BY CreatedDate ASC
                LIMIT 1
            ];
            if (ocrs.isEmpty()) return;
            Contact sc = new Contact(Id = ocrs[0].ContactId);
            tryPut(sc, contactFieldName, newValue);
            update sc;
        } catch (Exception ex) {
            System.debug(LoggingLevel.WARN,
                'stampStudentContact failed for opp=' + opportunityId
                + ' field=' + contactFieldName + ': ' + ex.getMessage());
        }
    }

    // Build a display-friendly user name from FirstName + LastName, falling back to Name.
    private static String composeUserName(String firstName, String lastName, String fallbackName) {
        String fn = (firstName != null) ? firstName.trim() : '';
        String ln = (lastName != null) ? lastName.trim() : '';
        String composed = (fn + ' ' + ln).trim();
        if (String.isNotBlank(composed)) return composed;
        return (fallbackName != null) ? fallbackName.trim() : '';
    }

    // Expected appointment length in minutes for a given booking type, or null if unknown.
    private static Integer expectedDurationMinutes(String bType) {
        if (bType == 'IC')    return 60;
        if (bType == 'PD')    return 60;
        if (bType == 'PD-FU') return 30;
        if (bType == 'FSS')   return 30;
        return null;
    }

    // Filter territories down to those whose WorkType duration matches the booking length.
    private static Set<Id> filterTerritoriesByDuration(
        Set<Id> territoryIds, Integer expectedMins
    ) {
        Set<Id> matching = new Set<Id>();
        if (territoryIds == null || territoryIds.isEmpty() || expectedMins == null) return matching;

        try {
            for (ServiceTerritoryWorkType stwt : [
                SELECT ServiceTerritoryId,
                       WorkType.DurationInMinutes, WorkType.DurationType
                FROM ServiceTerritoryWorkType
                WHERE ServiceTerritoryId IN :territoryIds
                AND WorkType.DurationInMinutes != NULL
            ]) {
                Integer dur = workTypeDurationInMinutes(
                    stwt.WorkType.DurationInMinutes, stwt.WorkType.DurationType);
                if (dur != null && dur == expectedMins) {
                    matching.add(stwt.ServiceTerritoryId);
                }
            }
        } catch (Exception ex) { }
        if (!matching.isEmpty()) return matching;

        Map<Id, Id> territoryToOH = new Map<Id, Id>();
        try {
            for (ServiceTerritory t : [
                SELECT Id, OperatingHoursId FROM ServiceTerritory
                WHERE Id IN :territoryIds AND OperatingHoursId != NULL
            ]) {
                territoryToOH.put(t.Id, t.OperatingHoursId);
            }
        } catch (Exception ex) { return matching; }
        if (territoryToOH.isEmpty()) return matching;

        Set<Id> matchingOH = new Set<Id>();
        try {
            for (WorkType wt : [
                SELECT OperatingHoursId, DurationInMinutes, DurationType
                FROM WorkType
                WHERE OperatingHoursId IN :territoryToOH.values()
                AND DurationInMinutes != NULL
            ]) {
                Integer dur = workTypeDurationInMinutes(
                    wt.DurationInMinutes, wt.DurationType);
                if (dur != null && dur == expectedMins) {
                    matchingOH.add(wt.OperatingHoursId);
                }
            }
        } catch (Exception ex) { return matching; }
        for (Id tId : territoryToOH.keySet()) {
            if (matchingOH.contains(territoryToOH.get(tId))) matching.add(tId);
        }
        return matching;
    }

    // Normalise WorkType.DurationInMinutes to absolute minutes accounting for DurationType.
    private static Integer workTypeDurationInMinutes(Decimal raw, String durationType) {
        if (raw == null) return null;
        Integer mins = Integer.valueOf(raw);
        if (durationType == 'Hours') mins = mins * 60;
        return mins;
    }

    // Parse a comma-separated guest-email string into a cleaned, deduped, lowercased list.
    private static List<String> parseGuestEmails(String guestEmails) {
        List<String> out = new List<String>();
        if (String.isBlank(guestEmails)) return out;
        Set<String> seen = new Set<String>();
        for (String raw : guestEmails.split(',')) {
            String cleaned = (raw == null) ? '' : raw.trim().toLowerCase();
            if (String.isBlank(cleaned)) continue;
            if (!cleaned.contains('@') || !cleaned.contains('.')) continue;
            if (seen.contains(cleaned)) continue;
            seen.add(cleaned);
            out.add(cleaned);
        }
        return out;
    }

    // Build the Lead.Description text (notes + acknowledgements + grade + guests).
    private static String buildLeadDescription(String notes, String studentGrade, List<String> guestList) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(notes)) {
            parts.add('Notes from attendee:');
            parts.add(notes.trim());
            parts.add('---');
        }
        parts.add('Booked via guest scheduler.');
        parts.add('Confirmed: will attend consultation; acknowledged 3-day rescheduling policy.');
        if (String.isNotBlank(studentGrade)) parts.add('Student grade: ' + studentGrade);
        if (guestList != null && !guestList.isEmpty()) {
            parts.add('Guests invited: ' + String.join(guestList, ', '));
        }
        return String.join(parts, '\n');
    }

    // Send a simple invitation email to each guest of an IC booking.
    private static void sendGuestInvitations(
        List<String> guests, DateTime startDT, DateTime endDT,
        String firstName, String lastName, String primaryEmail, String tz
    ) {
        if (guests == null || guests.isEmpty()) return;
        String tzDisplay = String.isNotBlank(tz) ? tz : 'America/Chicago';
        String meetingTime = startDT.format('EEEE, MMMM d, yyyy h:mm a', tzDisplay)
            + ' (' + tzDisplay + ')';
        String subject = 'You\'re invited: Initial Consultation with Zenith Prep Academy';
        String body =
            'Hello,\n\n'
            + (firstName + ' ' + lastName).trim()
            + ' has invited you to attend an Initial Consultation with Zenith Prep Academy.\n\n'
            + 'When: ' + meetingTime + '\n'
            + 'Where: Zoom (the join link will arrive in a follow-up email)\n\n'
            + 'If you have questions, please reply to ' + primaryEmail + '.\n\n'
            + 'Thank you,\nZenith Prep Academy';

        List<Messaging.SingleEmailMessage> msgs = new List<Messaging.SingleEmailMessage>();
        for (String guestAddr : guests) {
            Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
            m.setToAddresses(new List<String>{ guestAddr });
            m.setSubject(subject);
            m.setPlainTextBody(body);
            m.setSaveAsActivity(false);
            msgs.add(m);
        }
        if (!msgs.isEmpty()) {
            Messaging.sendEmail(msgs, false);
        }
    }

    // Build the Event/SA Description text (notes + invited guests). Returns null when empty.
    private static String buildEventDescription(String notes, List<String> guestList) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(notes)) {
            parts.add('Notes from attendee:');
            parts.add(notes.trim());
        }
        if (guestList != null && !guestList.isEmpty()) {
            if (!parts.isEmpty()) parts.add('');
            parts.add('Guests invited: ' + String.join(guestList, ', '));
        }
        return parts.isEmpty() ? null : String.join(parts, '\n');
    }
}
