public without sharing class GuestSchedulerController {

    private static final String ADMISSION_PROFILE_NAME     = 'Admission Counsellor';
    private static final String ADMISSION_PROFILE_NAME_ALT = 'Admission Counselor';
    private static final Integer DEFAULT_SCAN_DAYS     = 30;
    private static final Integer DEFAULT_ADVANCE_HOURS = 2;
    private static DiscoveredConfig cachedDiscovery;

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

    private static Database.DMLOptions dmlAllowDupes() {
        Database.DMLOptions d = new Database.DMLOptions();
        d.DuplicateRuleHeader.allowSave = true;
        d.DuplicateRuleHeader.runAsCurrentUser = false;
        return d;
    }

    private static Integer countFreeResources(
        ResourceBundle rb,
        Map<Id, List<List<DateTime>>> rawBusy,
        DateTime slotStart,
        DateTime slotEnd
    ) {
        Integer freeCount = 0;
        for (Id rId : rb.resourceIds) {
            List<List<DateTime>> ivs = rawBusy.get(rId);
            Boolean free = true;
            if (ivs != null) {
                for (List<DateTime> iv : ivs) {
                    if (slotStart < iv[1] && slotEnd > iv[0]) {
                        free = false;
                        break;
                    }
                }
            }
            if (free) {
                freeCount++;
            }
        }
        return freeCount;
    }

    private static DiscoveredConfig discover() {
        if (cachedDiscovery != null) return cachedDiscovery;
        DiscoveredConfig cfg = new DiscoveredConfig();
        Date today = Date.today();
        Date scanEnd = today.addDays(DEFAULT_SCAN_DAYS);

        Set<Id> counselorUserIds = new Set<Id>();
        for (User u : [
            SELECT Id FROM User
            WHERE (Profile.Name = :ADMISSION_PROFILE_NAME
                   OR Profile.Name = :ADMISSION_PROFILE_NAME_ALT)
            AND IsActive = true
        ]) {
            counselorUserIds.add(u.Id);
        }
        if (counselorUserIds.isEmpty())
            throw new AuraHandledException('No active Admission Counsellor users found.');

        Set<Id> resourceIds = new Set<Id>();
        for (ServiceResource sr : [
            SELECT Id FROM ServiceResource
            WHERE RelatedRecordId IN :counselorUserIds AND IsActive = true
        ]) {
            resourceIds.add(sr.Id);
        }
        if (resourceIds.isEmpty())
            throw new AuraHandledException('No Service Resources for counsellors.');

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
            throw new AuraHandledException('No territories for counsellor resources.');

        List<ServiceTerritory> territories = [
            SELECT Id, Name, IsActive, OperatingHoursId,
                   OperatingHours.TimeZone, Street, City, State
            FROM ServiceTerritory WHERE Id IN :rawTerritoryIds
            ORDER BY CreatedDate DESC
        ];
        ServiceTerritory st = null;
        for (ServiceTerritory t : territories) {
            if (t.OperatingHoursId != null) {
                st = t;
                break;
            }
        }
        if (st == null && !territories.isEmpty()) st = territories[0];
        if (st == null) throw new AuraHandledException('No ServiceTerritory found.');

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
                ]) {
                    wt = stwt.WorkType;
                }
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
        cfg.durationMinutes = Integer.valueOf(wt.DurationInMinutes);
        cfg.durationType = wt.DurationType;
        cfg.appointmentType = wt.DefaultAppointmentType;
        cfg.slotIntervalMinutes = (wt.ApptStartTimeIntvlInMin != null && wt.ApptStartTimeIntvlInMin > 0)
            ? wt.ApptStartTimeIntvlInMin : cfg.durationMinutes;
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

        cachedDiscovery = cfg;
        return cfg;
    }

    @AuraEnabled
    public static Map<String, Object> getBookingConfig(Integer openWindowDays) {
        Map<String, Object> out = new Map<String, Object>();
        try {
            DiscoveredConfig cfg = discover();
            Integer targetDays = (openWindowDays != null && openWindowDays > 0)
                ? openWindowDays : cfg.timeframeEndDays;
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
            out.put('availableDates', computeAvailableDates(cfg, targetDays));
            out.put('success', true);
        } catch (Exception e) {
            out.put('success', false);
            out.put('error', e.getMessage());
        }
        return out;
    }

    @AuraEnabled
    public static List<Map<String, String>> getAvailableSlots(String dateStr) {
        List<Map<String, String>> result = new List<Map<String, String>>();
        try {
            DiscoveredConfig cfg = discover();
            Date reqDate = Date.valueOf(dateStr);
            String tzId = cfg.territoryTimezone;
            TimeZone tz = TimeZone.getTimeZone(tzId);
            Date today = Date.today();
            Date scanEnd = today.addDays(cfg.timeframeEndDays - 1);

            Map<String, List<TimeSlot>> slotsByDay = loadOperatingHours(cfg.operatingHoursId);
            ResourceBundle rb = loadResources(cfg.allTerritoryIds, today, scanEnd);
            if (rb.resourceIds.isEmpty()) return result;

            DateTime dayStart = localToUtc(reqDate, 0, tz);
            DateTime dayEnd = localToUtc(reqDate.addDays(1), 0, tz);
            DateTime busyRangeStart = dayStart.addHours(-2);
            DateTime busyRangeEnd = dayEnd.addHours(2);

            Map<Id, List<List<DateTime>>> rawBusy =
                buildRawBusyMap(rb, cfg.allTerritoryIds, busyRangeStart, busyRangeEnd);

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
        } catch (Exception e) {
        }
        return result;
    }

    @AuraEnabled
    public static Map<String, String> bookAppointment(
        String startTimeISO, String endTimeISO,
        String firstName, String lastName, String email, String phone,
        String studentGrade, String leadSource, String guestEmails,
        String clientTimezone, String utmSource, String utmCampaign, String utmMedium
    ) {
        Map<String, String> res = new Map<String, String>();
        Savepoint sp = Database.setSavepoint();
        try {
            DateTime startDT = parseISO(startTimeISO);
            DateTime endDT = parseISO(endTimeISO);
            String cleanEmail = email.trim().toLowerCase();
            String cleanFirst = firstName.trim();
            String cleanLast = lastName.trim();
            String cleanPhone = phone.trim();
            Database.DMLOptions dmlOpts = dmlAllowDupes();
            DiscoveredConfig cfg = discover();

            ResourceAssignment assignment = findAvailableResourceRoundRobin(cfg, startDT, endDT);
            if (assignment == null) {
                res.put('success', 'false');
                res.put('error', 'SLOT_UNAVAILABLE');
                return res;
            }

            Lead mktLead = new Lead(
                FirstName = cleanFirst, LastName = cleanLast, Email = cleanEmail,
                Phone = cleanPhone,
                LeadSource = leadSource,
                Status = 'IC Scheduled', 
                Meeting_Status__c = 'Scheduled',
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
            booking.Subject = 'Initial Consultation - Zenith Prep Academy';
            booking.StartDateTime = startDT;
            booking.EndDateTime = startDT.addMinutes(60);
            booking.ShowAs = 'Busy';
            booking.Type  = 'Meeting';
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
                sa.Subject = 'Initial Consultation - Zenith Prep Academy';
                sa.Street = cfg.street;
                sa.City = cfg.city;
                sa.State = cfg.state;
                sa.Phone = cleanPhone;
                sa.Email = cleanEmail;
                sa.Meeting_Type__c = 'Initial Consultation';
                sa.AdditionalInformation = cfg.workTypeName;
                sa.Admission_Counselor__c = assignment.userId;
                sa.Student_Grade__c = studentGrade;
                insert sa;

                AssignedResource ar = new AssignedResource();
                ar.ServiceAppointmentId = sa.Id;
                ar.ServiceResourceId = assignment.resourceId;
                insert ar;

                res.put('appointmentId', sa.Id);
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

        } catch (AuraHandledException ae) {
            Database.rollback(sp);
            throw ae;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Problem saving booking: ' + e.getMessage());
        }
        return res;
    }

    private static ResourceAssignment findAvailableResourceRoundRobin(
        DiscoveredConfig cfg, DateTime startDT, DateTime endDT
    ) {
        Date today = Date.today();
        Date scanEnd = today.addDays(cfg.timeframeEndDays - 1);
        ResourceBundle rb = loadResources(cfg.allTerritoryIds, today, scanEnd);
        if (rb.resourceIds.isEmpty()) return null;

        DateTime busyStart = startDT.addHours(-2);
        DateTime busyEnd = endDT.addHours(2);
        Map<Id, List<List<DateTime>>> rawBusy =
            buildRawBusyMap(rb, cfg.allTerritoryIds, busyStart, busyEnd);

        List<Id> freeRes = new List<Id>();
        for (Id rId : rb.orderedResourceIds) {
            List<List<DateTime>> ivs = rawBusy.get(rId);
            Boolean free = true;
            if (ivs != null) {
                for (List<DateTime> iv : ivs) {
                    if (startDT < iv[1] && endDT > iv[0]) {
                        free = false;
                        break;
                    }
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
            if (c < minC) {
                minC = c;
                bestId = rId;
            }
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
                        utcToLocalMinutes(iv[0], d, tz),
                        utcToLocalMinutes(iv[1], d, tz)
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

        ResourceBundle rb = loadResources(cfg.allTerritoryIds, today, scanEnd);
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
                if (countFreeResources(rb, rawBusy, si.startUtc, si.endUtc) > 0) {
                    hasAvail = true;
                    break;
                }
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
        Set<Id> territoryIds, Date rangeStart, Date rangeEnd
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
            if (sr.RelatedRecordId != null
                && String.valueOf(sr.RelatedRecordId).startsWith('005')) {
                srToUser.put(sr.Id, sr.RelatedRecordId);
            }
        }
        if (srToUser.isEmpty()) return rb;

        Set<Id> admUsers = new Set<Id>();
        for (User u : [
            SELECT Id FROM User WHERE Id IN :srToUser.values()
            AND (Profile.Name = :ADMISSION_PROFILE_NAME
                 OR Profile.Name = :ADMISSION_PROFILE_NAME_ALT)
            AND IsActive = true
        ]) {
            admUsers.add(u.Id);
        }

        for (Id srId : srToUser.keySet()) {
            if (admUsers.contains(srToUser.get(srId))) {
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
            for (AssignedResource ar : [
                SELECT ServiceAppointmentId, ServiceResourceId FROM AssignedResource
                WHERE ServiceAppointmentId IN :saMap.keySet()
                AND ServiceResourceId IN :rb.resourceIds
            ]) {
                ServiceAppointment sa = saMap.get(ar.ServiceAppointmentId);
                if (sa != null && busy.containsKey(ar.ServiceResourceId)) {
                    busy.get(ar.ServiceResourceId).add(
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
                if (ss < iv[1] && se > iv[0]) {
                    free = false;
                    break;
                }
            }
            if (free) return true;
        }
        return false;
    }

    private static DateTime localToUtc(Date d, Integer mins, TimeZone tz) {
        if (mins >= 1440) {
            d = d.addDays(mins / 1440);
            mins = Math.mod(mins, 1440);
        }
        DateTime g = DateTime.newInstanceGmt(d, Time.newInstance(mins/60, Math.mod(mins,60), 0, 0));
        return g.addSeconds(-(tz.getOffset(g) / 1000));
    }

    private static Integer utcToLocalMinutes(DateTime utcDT, Date ref, TimeZone tz) {
        DateTime loc = utcDT.addSeconds(tz.getOffset(utcDT) / 1000);
        String hm = loc.formatGmt('HH:mm');
        List<String> p = hm.split(':');
        return Integer.valueOf(p[0]) * 60 + Integer.valueOf(p[1]);
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