public without sharing class GuestSchedulerController {

    private static final String ADMISSION_PROFILE_NAME     = 'Admission Counsellor';
    private static final String ADMISSION_PROFILE_NAME_ALT = 'Admission Counselor';
    private static final String PD_PROFILE_NAME            = 'Program Director';
    private static final String FSS_PROFILE_NAME           = 'FSS Onboarding';
    private static final Integer DEFAULT_SCAN_DAYS     = 30;
    private static final Integer DEFAULT_ADVANCE_HOURS = 2;
    private static Map<String, DiscoveredConfig> cachedDiscoveryMap = new Map<String, DiscoveredConfig>();

    private static final Map<String, String> MEETING_TYPE_MAP = new Map<String, String>{
        'IC'  => 'Initial Consultation',
        'PD'  => 'Program Director - 60 Minutes',
        'FSS' => 'FSS Onboarding Meeting'
    };
    private static final Map<String, String> SUBJECT_MAP = new Map<String, String>{
        'IC'  => 'Initial Consultation - Zenith Prep Academy',
        'PD'  => 'Program Director - 60 Minutes - Zenith Prep Academy',
        'FSS' => 'FSS Onboarding Meeting - Zenith Prep Academy'
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

    private static String normalizeType(String bookingType) {
        if (String.isBlank(bookingType) || bookingType == 'IC') return 'IC';
        return bookingType.toUpperCase();
    }

    private static List<String> getProfileNames(String bType) {
        if (bType == 'PD') return new List<String>{ PD_PROFILE_NAME };
        if (bType == 'FSS') return new List<String>{ FSS_PROFILE_NAME };
        return new List<String>{ ADMISSION_PROFILE_NAME, ADMISSION_PROFILE_NAME_ALT };
    }

    private static Database.DMLOptions dmlAllowDupes() {
        Database.DMLOptions d = new Database.DMLOptions();
        d.DuplicateRuleHeader.allowSave = true;
        d.DuplicateRuleHeader.runAsCurrentUser = false;
        return d;
    }

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
            throw new AuraHandledException('No active users found for ' + bType + ' booking.');

        Set<Id> resourceIds = new Set<Id>();
        for (ServiceResource sr : [
            SELECT Id FROM ServiceResource
            WHERE RelatedRecordId IN :userIds AND IsActive = true
        ]) {
            resourceIds.add(sr.Id);
        }
        if (resourceIds.isEmpty())
            throw new AuraHandledException('No Service Resources found for ' + bType + ' users.');

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
            throw new AuraHandledException('No territories found for ' + bType + ' resources.');

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
        if (territories.isEmpty()) throw new AuraHandledException('No ServiceTerritory found for ' + bType + '.');

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
            throw new AuraHandledException('No OperatingHours on territory "' + st.Name + '".');

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
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (!wtsByOH.isEmpty()) wt = wtsByOH[0];
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
        if (wt == null) throw new AuraHandledException('No WorkType found.');

        cfg.workTypeId = wt.Id;
        cfg.workTypeName = wt.Name;
        cfg.durationType = wt.DurationType;
        cfg.appointmentType = wt.DefaultAppointmentType;

        if (bType == 'PD') {
            cfg.durationMinutes = 60;
            cfg.slotIntervalMinutes = 45;
        } else if (bType == 'FSS') {
            cfg.durationMinutes = 30;
            cfg.slotIntervalMinutes = 30;
        } else {
            cfg.durationMinutes = Integer.valueOf(wt.DurationInMinutes);
            cfg.slotIntervalMinutes = (wt.ApptStartTimeIntvlInMin != null && wt.ApptStartTimeIntvlInMin > 0)
                ? wt.ApptStartTimeIntvlInMin : cfg.durationMinutes;
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
                           Meeting_Type__c, Opportunity__c, OwnerId, Owner.Name
                    FROM ServiceAppointment
                    WHERE Reschedule_Token__c = :rescheduleToken
                    LIMIT 1
                ];
                if (origs.isEmpty()) {
                    out.put('success', false);
                    out.put('error', 'LINK_ALREADY_USED');
                    return out;
                }
                ServiceAppointment orig = origs[0];
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
                if (orig.Owner != null && String.isNotBlank(orig.Owner.Name)) {
                    out.put('counselorName', orig.Owner.Name);
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
        } catch (Exception e) {
            out.put('success', false);
            out.put('error', e.getMessage());
        }
        return out;
    }

    @AuraEnabled
    public static List<Map<String, String>> getAvailableSlots(String dateStr, String bookingType,
                                                               String contactId, String opportunityId) {
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

            if (cfg.bookingType == 'PD') {
                Id stickyId = findStickyResourceForContact(contactId, opportunityId);
                if (stickyId != null && rb.resourceIds.contains(stickyId)) {
                    ResourceBundle stickyRb = new ResourceBundle();
                    stickyRb.resourceIds.add(stickyId);
                    stickyRb.orderedResourceIds.add(stickyId);
                    stickyRb.resourceToUserId.put(stickyId, rb.resourceToUserId.get(stickyId));
                    stickyRb.resourceToTerritoryId.put(stickyId, rb.resourceToTerritoryId.get(stickyId));
                    rb = stickyRb;
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

    @AuraEnabled
    public static Map<String, String> bookAppointment(
        String startTimeISO, String endTimeISO,
        String firstName, String lastName, String email, String phone,
        String studentGrade, String leadSource, String guestEmails,
        String clientTimezone, String utmSource, String utmCampaign, String utmMedium,
        String bookingType, String contactId, String opportunityId,
        String rescheduleToken
    ) {
        Map<String, String> res = new Map<String, String>();
        Savepoint sp = Database.setSavepoint();
        try {
            String bType = normalizeType(bookingType);
            DateTime startDT = parseISO(startTimeISO);
            DateTime endDT = parseISO(endTimeISO);

            ServiceAppointment originalSA = null;
            Boolean isReschedule = String.isNotBlank(rescheduleToken);
            if (isReschedule) {
                List<ServiceAppointment> origs = [
                    SELECT Id, Status, ContactId, AccountId, ParentRecordId,
                           Meeting_Type__c, Opportunity__c
                    FROM ServiceAppointment
                    WHERE Reschedule_Token__c = :rescheduleToken
                    LIMIT 1
                    FOR UPDATE
                ];
                if (origs.isEmpty()) {
                    res.put('success', 'false');
                    res.put('error', 'LINK_ALREADY_USED');
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

            if (isReschedule && originalSA != null) {
                ServiceAppointment cancelOrig = new ServiceAppointment(Id = originalSA.Id);
                cancelOrig.Status = 'Canceled';
                cancelOrig.Reschedule_Token__c = null;
                // Validation rule requires CancellationReason whenever Status = 'Canceled'.
                RescheduleTokenService.tryPutCancellationReason(cancelOrig, 'Rescheduled by user');
                try { cancelOrig.Description = 'Rescheduled by user.'; } catch (Exception ex) { }
                update cancelOrig;
                try {
                    List<Event> origEvents = [SELECT Id FROM Event WHERE Service_Appointment__c = :originalSA.Id];
                    if (!origEvents.isEmpty()) delete origEvents;
                } catch (Exception ex) { }
            }

            ResourceAssignment assignment = findAvailableResourceRoundRobin(cfg, startDT, endDT, bType, opportunityId);
            if (assignment == null) {
                if (isReschedule) Database.rollback(sp);
                res.put('success', 'false');
                res.put('error', 'SLOT_UNAVAILABLE');
                return res;
            }

            if (bType == 'IC') {
                bookIC(res, cfg, assignment, startDT, endDT,
                       firstName, lastName, email, phone, studentGrade,
                       leadSource, guestEmails, clientTimezone,
                       utmSource, utmCampaign, utmMedium);
            } else {
                bookPDorFSS(res, cfg, assignment, bType, startDT, endDT,
                            contactId, opportunityId, clientTimezone);
            }

            if (isReschedule && originalSA != null && 'true'.equals(res.get('success'))) {
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

    private static void bookIC(
        Map<String, String> res, DiscoveredConfig cfg, ResourceAssignment assignment,
        DateTime startDT, DateTime endDT,
        String firstName, String lastName, String email, String phone,
        String studentGrade, String leadSource, String guestEmails,
        String clientTimezone, String utmSource, String utmCampaign, String utmMedium
    ) {
        String cleanEmail = email.trim().toLowerCase();
        String cleanFirst = firstName.trim();
        String cleanLast = lastName.trim();
        String cleanPhone = phone.trim();
        Database.DMLOptions dmlOpts = dmlAllowDupes();

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
            sa.Student_Grade__c = studentGrade;
            sa.Reschedule_Token__c = RescheduleTokenService.generateToken();
            tryPut(sa, 'Customer_Name__c', cleanFirst + ' ' + cleanLast);
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
    }

    private static void bookPDorFSS(
        Map<String, String> res, DiscoveredConfig cfg, ResourceAssignment assignment,
        String bType, DateTime startDT, DateTime endDT,
        String contactId, String opportunityId, String clientTimezone
    ) {
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
        insert sa;

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
            insert evt;
        } catch (Exception evtEx) { }

        try {
            ServiceResource pdSr = [SELECT Appointment_Count__c FROM ServiceResource WHERE Id = :assignment.resourceId LIMIT 1];
            pdSr.Appointment_Count__c = (pdSr.Appointment_Count__c != null) ? pdSr.Appointment_Count__c + 1 : 1;
            update pdSr;
        } catch (Exception srEx) { }

        if (bType == 'PD' && String.isNotBlank(opportunityId)) {
            try {
                Opportunity opp = [SELECT Id, Program_Director__c FROM Opportunity WHERE Id = :opportunityId LIMIT 1];
                if (opp.Program_Director__c == null) { opp.Program_Director__c = assignment.userId; update opp; }
            } catch (Exception ex) { }
            if (conId != null) {
                try {
                    Contact con = [SELECT Id, Program_Director__c FROM Contact WHERE Id = :conId LIMIT 1];
                    if (con.Program_Director__c == null) { con.Program_Director__c = assignment.userId; update con; }
                } catch (Exception ex) { }
            }
        }

        if (bType == 'FSS') {
            if (String.isNotBlank(opportunityId)) {
                try {
                    Opportunity opp = [SELECT Id, Family_Success_Specialist__c FROM Opportunity WHERE Id = :opportunityId LIMIT 1];
                    if (opp.Family_Success_Specialist__c == null) { opp.Family_Success_Specialist__c = assignment.userId; update opp; }
                } catch (Exception ex) { }
            }
            if (conId != null) {
                try {
                    Contact con = [SELECT Id, Family_Success_Specialist__c FROM Contact WHERE Id = :conId LIMIT 1];
                    if (con.Family_Success_Specialist__c == null) { con.Family_Success_Specialist__c = assignment.userId; update con; }
                } catch (Exception ex) { }
            }
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

    private static Boolean isOneTimeUseType(String bType) {
        return bType == 'PD' || bType == 'FSS';
    }

    private static final String BOOKING_BASE_URL =
        'https://site-enterprise-6958--dev2.sandbox.my.site.com/booking';

    private static void stampActionUrls(Map<String, String> res, String token) {
        if (String.isBlank(token)) return;
        res.put('rescheduleUrl', BOOKING_BASE_URL + '?token=' + token + '&action=reschedule');
        res.put('cancelUrl',     BOOKING_BASE_URL + '?token=' + token + '&action=cancel');
    }

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

    private static ResourceAssignment findAvailableResourceRoundRobin(
        DiscoveredConfig cfg, DateTime startDT, DateTime endDT, String bType, String opportunityId
    ) {
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

    private static DateTime localToUtc(Date d, Integer mins, TimeZone tz) {
        if (mins >= 1440) { d = d.addDays(mins / 1440); mins = Math.mod(mins, 1440); }
        DateTime g = DateTime.newInstanceGmt(d, Time.newInstance(mins/60, Math.mod(mins,60), 0, 0));
        return g.addSeconds(-(tz.getOffset(g) / 1000));
    }

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

    private static String normalizeTimezone(String tz) {
        return TZ_ALIASES.containsKey(tz) ? TZ_ALIASES.get(tz) : tz;
    }

    private static DateTime parseISO(String iso) {
        return DateTime.valueOfGmt(iso.replace('T',' ').replace('Z',''));
    }

    private static String toDateStr(Date d) {
        return String.valueOf(d.year()) + '-' + String.valueOf(d.month()).leftPad(2,'0')
            + '-' + String.valueOf(d.day()).leftPad(2,'0');
    }

    private static void tryPut(SObject rec, String f, Object v) {
        try { rec.put(f, v); } catch (Exception ex) { }
    }
}
