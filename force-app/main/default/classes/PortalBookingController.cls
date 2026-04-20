public without sharing class PortalBookingController {

    private static final Map<String, String> PROFILE_MAP = new Map<String, String>{
        'PD' => 'Program Director',
        'FSS' => 'FSS Onboarding',
        'IC' => 'Admission Counsellor'
    };

    private static final Map<String, String> MEETING_TYPE_MAP = new Map<String, String>{
        'PD' => 'Program Director - 60 Minutes',
        'FSS' => 'FSS Onboarding Meeting',
        'IC' => 'Initial Consultation'
    };

    private static final Map<String, String> SUBJECT_MAP = new Map<String, String>{
        'PD' => 'Program Director - 60 Minutes - Zenith Prep Academy',
        'FSS' => 'FSS Onboarding Meeting - Zenith Prep Academy',
        'IC' => 'Initial Consultation - Zenith Prep Academy'
    };

    private static final Integer DEFAULT_SCAN_DAYS = 30;
    private static final Integer DEFAULT_ADVANCE_HOURS = 2;

    private class SlotInfo {
        DateTime startUtc;
        DateTime endUtc;
    }

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getBookingConfig(String bookingType, String contactId) {
        Map<String, Object> out = new Map<String, Object>();
        try {
            String profileName = resolveProfileName(bookingType);
            List<ServiceResource> resources = getActiveResources(profileName);
            if (resources.isEmpty()) {
                throw new AuraHandledException('No active ' + profileName + ' resources found.');
            }

            Set<Id> resourceIds = new Set<Id>();
            for (ServiceResource sr : resources) resourceIds.add(sr.Id);

            Date today = Date.today();
            Date scanEnd = today.addDays(DEFAULT_SCAN_DAYS);

            Set<Id> territoryIds = new Set<Id>();
            for (ServiceTerritoryMember stm : [
                SELECT ServiceTerritoryId FROM ServiceTerritoryMember
                WHERE ServiceResourceId IN :resourceIds
                AND EffectiveStartDate <= :scanEnd
                AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
                AND ServiceTerritory.IsActive = true
            ]) {
                territoryIds.add(stm.ServiceTerritoryId);
            }
            if (territoryIds.isEmpty()) {
                throw new AuraHandledException('No active territories found for ' + profileName + '.');
            }

            ServiceTerritory bestTerritory = findBestTerritory(territoryIds);
            if (bestTerritory == null) {
                throw new AuraHandledException('No ServiceTerritory with OperatingHours found.');
            }

            Id opHoursId = bestTerritory.OperatingHoursId;
            String tzStr = (bestTerritory.OperatingHours != null)
                ? bestTerritory.OperatingHours.TimeZone : 'America/New_York';

            Integer duration = 60;
            if (bookingType == 'FSS') duration = 30;

            Map<String, Object> contactInfo = new Map<String, Object>();
            if (String.isNotBlank(contactId)) {
                List<Contact> contacts = [
                    SELECT FirstName, LastName, Email, Phone, Account.Name
                    FROM Contact WHERE Id = :contactId LIMIT 1
                ];
                if (!contacts.isEmpty()) {
                    Contact c = contacts[0];
                    contactInfo.put('firstName', c.FirstName);
                    contactInfo.put('lastName', c.LastName);
                    contactInfo.put('email', c.Email);
                    contactInfo.put('phone', c.Phone);
                    contactInfo.put('accountName', c.Account != null ? c.Account.Name : '');
                }
            }

            List<String> availDates = computeAvailableDates(
                opHoursId, resourceIds, territoryIds, duration, DEFAULT_SCAN_DAYS, tzStr
            );

            out.put('durationMinutes', duration);
            out.put('territoryTimezone', tzStr);
            out.put('bookingType', bookingType);
            out.put('meetingType', MEETING_TYPE_MAP.get(bookingType));
            out.put('availableDates', availDates);
            out.put('contactInfo', contactInfo);
            out.put('resourceCount', resources.size());
            out.put('success', true);
        } catch (Exception e) {
            out.put('success', false);
            out.put('error', e.getMessage());
        }
        return out;
    }

    @AuraEnabled
    public static List<Map<String, String>> getAvailableSlots(String bookingType, String dateStr) {
        List<Map<String, String>> result = new List<Map<String, String>>();
        try {
            String profileName = resolveProfileName(bookingType);
            List<ServiceResource> resources = getActiveResources(profileName);
            if (resources.isEmpty()) return result;

            Set<Id> resourceIds = new Set<Id>();
            Map<Id, Id> resourceToUser = new Map<Id, Id>();
            for (ServiceResource sr : resources) {
                resourceIds.add(sr.Id);
                resourceToUser.put(sr.Id, sr.RelatedRecordId);
            }

            Date today = Date.today();
            Date scanEnd = today.addDays(DEFAULT_SCAN_DAYS);

            Set<Id> territoryIds = new Set<Id>();
            for (ServiceTerritoryMember stm : [
                SELECT ServiceTerritoryId FROM ServiceTerritoryMember
                WHERE ServiceResourceId IN :resourceIds
                AND EffectiveStartDate <= :scanEnd
                AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
                AND ServiceTerritory.IsActive = true
            ]) {
                territoryIds.add(stm.ServiceTerritoryId);
            }

            ServiceTerritory bestTerritory = findBestTerritory(territoryIds);
            if (bestTerritory == null) return result;

            String tzStr = (bestTerritory.OperatingHours != null)
                ? bestTerritory.OperatingHours.TimeZone : 'America/New_York';
            TimeZone tz = TimeZone.getTimeZone(tzStr);
            Date reqDate = Date.valueOf(dateStr);

            Integer duration = (bookingType == 'FSS') ? 30 : 60;
            Integer interval = (bookingType == 'FSS') ? 30 : 45;

            Map<String, List<TimeSlot>> slotsByDay = loadOperatingHours(bestTerritory.OperatingHoursId);
            Map<Id, List<List<DateTime>>> busyMap = buildBusyMap(
                resourceIds, resourceToUser, territoryIds,
                localToUtc(reqDate, 0, tz).addHours(-2),
                localToUtc(reqDate.addDays(1), 0, tz).addHours(2)
            );

            DateTime noonGmt = DateTime.newInstanceGmt(reqDate, Time.newInstance(12,0,0,0));
            String dayName = noonGmt.format('EEEE', tzStr);
            List<TimeSlot> windows = slotsByDay.get(dayName);
            if (windows == null || windows.isEmpty()) return result;

            Integer nowLocal = utcToLocalMinutes(DateTime.now(), reqDate, tz);
            Integer minStart = (reqDate == today) ? nowLocal + (DEFAULT_ADVANCE_HOURS * 60) : 0;

            for (TimeSlot tw : windows) {
                Integer ws = tw.StartTime.hour()*60 + tw.StartTime.minute();
                Integer we = tw.EndTime.hour()*60 + tw.EndTime.minute();
                Integer ss = ws;
                while (ss + duration <= we) {
                    if (ss >= minStart) {
                        DateTime slotStart = localToUtc(reqDate, ss, tz);
                        DateTime slotEnd = localToUtc(reqDate, ss + duration, tz);
                        Integer freeCount = countFree(resourceIds, busyMap, slotStart, slotEnd);
                        if (freeCount > 0) {
                            result.add(new Map<String, String>{
                                'startUtc' => slotStart.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
                                'endUtc' => slotEnd.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
                                'availableCount' => String.valueOf(freeCount)
                            });
                        }
                    }
                    ss += interval;
                }
            }
        } catch (Exception e) { }
        return result;
    }

    @AuraEnabled
    public static Map<String, String> bookAppointment(
        String bookingType, String contactId, String opportunityId,
        String startTimeISO, String endTimeISO, String clientTimezone
    ) {
        Map<String, String> res = new Map<String, String>();
        Savepoint sp = Database.setSavepoint();
        try {
            DateTime startDT = parseISO(startTimeISO);
            DateTime endDT = parseISO(endTimeISO);
            String profileName = resolveProfileName(bookingType);
            String meetingType = MEETING_TYPE_MAP.get(bookingType);
            String subject = SUBJECT_MAP.get(bookingType);

            Id assignedUserId = null;
            Id assignedResourceId = null;

            if (bookingType == 'PD' && String.isNotBlank(opportunityId)) {
                List<Opportunity> opps = [
                    SELECT Program_Director__c FROM Opportunity
                    WHERE Id = :opportunityId LIMIT 1
                ];
                if (!opps.isEmpty() && opps[0].Program_Director__c != null) {
                    assignedUserId = opps[0].Program_Director__c;
                    List<ServiceResource> srs = [
                        SELECT Id FROM ServiceResource
                        WHERE RelatedRecordId = :assignedUserId AND IsActive = true LIMIT 1
                    ];
                    if (!srs.isEmpty()) {
                        assignedResourceId = srs[0].Id;
                        if (!isResourceFree(assignedResourceId, assignedUserId, startDT, endDT)) {
                            assignedUserId = null;
                            assignedResourceId = null;
                        }
                    }
                }
            }

            if (assignedResourceId == null) {
                List<ServiceResource> resources = getActiveResources(profileName);
                Map<Id, Id> rToU = new Map<Id, Id>();
                Set<Id> rIds = new Set<Id>();
                for (ServiceResource sr : resources) {
                    rIds.add(sr.Id);
                    rToU.put(sr.Id, sr.RelatedRecordId);
                }

                Date today = Date.today();
                Set<Id> tIds = new Set<Id>();
                for (ServiceTerritoryMember stm : [
                    SELECT ServiceTerritoryId FROM ServiceTerritoryMember
                    WHERE ServiceResourceId IN :rIds
                    AND EffectiveStartDate <= :today
                    AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
                    AND ServiceTerritory.IsActive = true
                ]) {
                    tIds.add(stm.ServiceTerritoryId);
                }

                Map<Id, List<List<DateTime>>> busyMap = buildBusyMap(
                    rIds, rToU, tIds, startDT.addHours(-1), endDT.addHours(1)
                );

                Id bestId = null;
                Decimal bestLoad = null;
                for (ServiceResource sr : resources) {
                    if (!rIds.contains(sr.Id)) continue;
                    Boolean free = true;
                    List<List<DateTime>> intervals = busyMap.get(sr.Id);
                    if (intervals != null) {
                        for (List<DateTime> iv : intervals) {
                            if (startDT < iv[1] && endDT > iv[0]) {
                                free = false;
                                break;
                            }
                        }
                    }
                    if (!free) continue;
                    Decimal count = (sr.Appointment_Count__c != null) ? sr.Appointment_Count__c : 0;
                    Decimal weight = (sr.Weight__c != null && sr.Weight__c > 0) ? sr.Weight__c : 1.0;
                    Decimal load = count / weight;
                    if (bestLoad == null || load < bestLoad) {
                        bestLoad = load;
                        bestId = sr.Id;
                    }
                }

                if (bestId == null) {
                    res.put('success', 'false');
                    res.put('error', 'No available ' + profileName + ' for the selected time slot.');
                    return res;
                }
                assignedResourceId = bestId;
                assignedUserId = rToU.get(bestId);
            }

            Id accountId = null;
            Id conId = null;
            if (String.isNotBlank(contactId)) {
                conId = (Id) contactId;
                List<Contact> contacts = [SELECT AccountId FROM Contact WHERE Id = :conId LIMIT 1];
                if (!contacts.isEmpty()) accountId = contacts[0].AccountId;
            }

            ServiceTerritory saTerritory = null;
            for (ServiceTerritoryMember stm : [
                SELECT ServiceTerritoryId, ServiceTerritory.Id, ServiceTerritory.Street,
                       ServiceTerritory.City, ServiceTerritory.State
                FROM ServiceTerritoryMember
                WHERE ServiceResourceId = :assignedResourceId
                AND ServiceTerritory.IsActive = true
                AND EffectiveStartDate <= :Date.today()
                AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :Date.today())
                ORDER BY CreatedDate DESC LIMIT 1
            ]) {
                saTerritory = stm.ServiceTerritory;
            }

            ServiceAppointment sa = new ServiceAppointment();
            sa.ParentRecordId = accountId;
            sa.ContactId = conId;
            if (saTerritory != null) {
                sa.ServiceTerritoryId = saTerritory.Id;
                sa.Street = saTerritory.Street;
                sa.City = saTerritory.City;
                sa.State = saTerritory.State;
            }
            sa.SchedStartTime = startDT;
            sa.SchedEndTime = endDT;
            sa.EarliestStartTime = startDT;
            sa.DueDate = endDT;
            sa.ArrivalWindowStartTime = startDT;
            sa.ArrivalWindowEndTime = endDT;
            sa.Status = 'Scheduled';
            sa.Subject = subject;
            sa.Meeting_Type__c = meetingType;
            sa.DurationType = 'Minutes';
            sa.AppointmentType = 'Meeting';
            sa.OwnerId = assignedUserId;
            if (String.isNotBlank(clientTimezone)) {
                sa.TimeZone = clientTimezone;
            }
            tryPut(sa, 'Program_Director__c', assignedUserId);
            if (String.isNotBlank(opportunityId)) {
                tryPut(sa, 'Opportunity__c', (Id) opportunityId);
            }
            insert sa;

            AssignedResource ar = new AssignedResource();
            ar.ServiceAppointmentId = sa.Id;
            ar.ServiceResourceId = assignedResourceId;
            insert ar;

            try {
                Event evt = new Event();
                evt.Subject = subject;
                evt.StartDateTime = startDT;
                evt.EndDateTime = endDT;
                evt.OwnerId = assignedUserId;
                evt.ShowAs = 'Busy';
                evt.Location = 'Zoom';
                if (conId != null) evt.WhoId = conId;
                if (String.isNotBlank(opportunityId)) evt.WhatId = (Id) opportunityId;
                tryPut(evt, 'Service_Appointment__c', sa.Id);
                insert evt;
            } catch (Exception evtEx) { }

            ServiceResource pdSr = [
                SELECT Appointment_Count__c FROM ServiceResource
                WHERE Id = :assignedResourceId LIMIT 1
            ];
            pdSr.Appointment_Count__c = (pdSr.Appointment_Count__c != null)
                ? pdSr.Appointment_Count__c + 1 : 1;
            update pdSr;

            if (bookingType == 'PD' && String.isNotBlank(opportunityId)) {
                try {
                    Opportunity opp = [SELECT Id, Program_Director__c FROM Opportunity
                                       WHERE Id = :opportunityId LIMIT 1];
                    if (opp.Program_Director__c == null) {
                        opp.Program_Director__c = assignedUserId;
                        update opp;
                    }
                } catch (Exception ex) { }

                if (conId != null) {
                    try {
                        Contact con = [SELECT Id, Program_Director__c FROM Contact
                                       WHERE Id = :conId LIMIT 1];
                        if (con.Program_Director__c == null) {
                            con.Program_Director__c = assignedUserId;
                            update con;
                        }
                    } catch (Exception ex) { }
                }
            }

            if (bookingType == 'FSS' && conId != null) {
                try {
                    Contact con = [SELECT Id, Family_Success_Specialist__c FROM Contact
                                   WHERE Id = :conId LIMIT 1];
                    if (con.Family_Success_Specialist__c == null) {
                        con.Family_Success_Specialist__c = assignedUserId;
                        update con;
                    }
                } catch (Exception ex) { }
            }

            User assignedUser = [SELECT Name FROM User WHERE Id = :assignedUserId LIMIT 1];

            res.put('success', 'true');
            res.put('appointmentId', sa.Id);
            res.put('appointmentNumber', [SELECT AppointmentNumber FROM ServiceAppointment WHERE Id = :sa.Id].AppointmentNumber);
            res.put('assignedTo', assignedUser.Name);
            res.put('meetingType', meetingType);
        } catch (AuraHandledException ae) {
            Database.rollback(sp);
            throw ae;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Booking failed: ' + e.getMessage());
        }
        return res;
    }

    private static String resolveProfileName(String bookingType) {
        String profileName = PROFILE_MAP.get(bookingType);
        if (profileName == null) {
            throw new AuraHandledException('Invalid booking type: ' + bookingType + '. Use PD, FSS, or IC.');
        }
        return profileName;
    }

    private static List<ServiceResource> getActiveResources(String profileName) {
        Set<Id> userIds = new Set<Id>();
        String altProfile = (profileName == 'Admission Counsellor') ? 'Admission Counselor' : profileName;
        for (User u : [
            SELECT Id FROM User
            WHERE (Profile.Name = :profileName OR Profile.Name = :altProfile)
            AND IsActive = true
        ]) {
            userIds.add(u.Id);
        }
        if (userIds.isEmpty()) return new List<ServiceResource>();

        return [
            SELECT Id, Name, RelatedRecordId, Appointment_Count__c, Weight__c
            FROM ServiceResource
            WHERE RelatedRecordId IN :userIds AND IsActive = true
            ORDER BY CreatedDate ASC
        ];
    }

    private static ServiceTerritory findBestTerritory(Set<Id> territoryIds) {
        List<ServiceTerritory> territories = [
            SELECT Id, Name, OperatingHoursId, OperatingHours.TimeZone,
                   Street, City, State
            FROM ServiceTerritory
            WHERE Id IN :territoryIds AND OperatingHoursId != null
            ORDER BY CreatedDate DESC
        ];
        if (territories.isEmpty()) return null;

        Map<Id, Id> territoryToOH = new Map<Id, Id>();
        for (ServiceTerritory st : territories) {
            territoryToOH.put(st.Id, st.OperatingHoursId);
        }
        Set<Id> ohIds = new Set<Id>(territoryToOH.values());
        Map<Id, Integer> ohSlotCount = new Map<Id, Integer>();
        for (TimeSlot ts : [SELECT OperatingHoursId FROM TimeSlot WHERE OperatingHoursId IN :ohIds]) {
            Integer cnt = ohSlotCount.containsKey(ts.OperatingHoursId)
                ? ohSlotCount.get(ts.OperatingHoursId) + 1 : 1;
            ohSlotCount.put(ts.OperatingHoursId, cnt);
        }

        ServiceTerritory best = null;
        Integer bestCount = 0;
        for (ServiceTerritory st : territories) {
            Integer cnt = ohSlotCount.containsKey(st.OperatingHoursId)
                ? ohSlotCount.get(st.OperatingHoursId) : 0;
            if (cnt > bestCount) {
                bestCount = cnt;
                best = st;
            }
        }
        return best != null ? best : territories[0];
    }

    private static List<String> computeAvailableDates(
        Id opHoursId, Set<Id> resourceIds, Set<Id> territoryIds,
        Integer duration, Integer scanDays, String tzStr
    ) {
        List<String> out = new List<String>();
        TimeZone tz = TimeZone.getTimeZone(tzStr);
        Date today = Date.today();
        Map<String, List<TimeSlot>> slotsByDay = loadOperatingHours(opHoursId);
        if (slotsByDay.isEmpty()) return out;

        Map<Id, Id> rToU = new Map<Id, Id>();
        for (ServiceResource sr : [
            SELECT Id, RelatedRecordId FROM ServiceResource
            WHERE Id IN :resourceIds AND IsActive = true
        ]) {
            rToU.put(sr.Id, sr.RelatedRecordId);
        }

        DateTime scanStartUtc = localToUtc(today, 0, tz).addHours(-2);
        DateTime scanEndUtc = localToUtc(today.addDays(scanDays + 1), 0, tz).addHours(2);
        Map<Id, List<List<DateTime>>> busyMap = buildBusyMap(
            resourceIds, rToU, territoryIds, scanStartUtc, scanEndUtc
        );

        Integer interval = (duration <= 30) ? 30 : 45;
        for (Integer i = 0; i < scanDays && out.size() < scanDays; i++) {
            Date d = today.addDays(i);
            DateTime noonGmt = DateTime.newInstanceGmt(d, Time.newInstance(12,0,0,0));
            String dayName = noonGmt.format('EEEE', tzStr);
            List<TimeSlot> windows = slotsByDay.get(dayName);
            if (windows == null || windows.isEmpty()) continue;

            Integer nowLocal = utcToLocalMinutes(DateTime.now(), d, tz);
            Integer minStart = (d == today) ? nowLocal + (DEFAULT_ADVANCE_HOURS * 60) : 0;
            Boolean hasAvail = false;

            for (TimeSlot tw : windows) {
                Integer ws = tw.StartTime.hour()*60 + tw.StartTime.minute();
                Integer we = tw.EndTime.hour()*60 + tw.EndTime.minute();
                Integer ss = ws;
                while (ss + duration <= we) {
                    if (ss >= minStart) {
                        DateTime slotStart = localToUtc(d, ss, tz);
                        DateTime slotEnd = localToUtc(d, ss + duration, tz);
                        if (countFree(resourceIds, busyMap, slotStart, slotEnd) > 0) {
                            hasAvail = true;
                            break;
                        }
                    }
                    ss += interval;
                }
                if (hasAvail) break;
            }
            if (hasAvail) {
                out.add(String.valueOf(d.year()) + '-'
                    + String.valueOf(d.month()).leftPad(2,'0') + '-'
                    + String.valueOf(d.day()).leftPad(2,'0'));
            }
        }
        return out;
    }

    private static Integer countFree(Set<Id> resourceIds, Map<Id, List<List<DateTime>>> busyMap,
                                     DateTime slotStart, DateTime slotEnd) {
        Integer freeCount = 0;
        for (Id rId : resourceIds) {
            List<List<DateTime>> intervals = busyMap.get(rId);
            Boolean free = true;
            if (intervals != null) {
                for (List<DateTime> iv : intervals) {
                    if (slotStart < iv[1] && slotEnd > iv[0]) {
                        free = false;
                        break;
                    }
                }
            }
            if (free) freeCount++;
        }
        return freeCount;
    }

    private static Boolean isResourceFree(Id resourceId, Id userId, DateTime startDT, DateTime endDT) {
        Integer saConflicts = [
            SELECT COUNT() FROM AssignedResource
            WHERE ServiceResourceId = :resourceId
            AND ServiceAppointment.SchedStartTime < :endDT
            AND ServiceAppointment.SchedEndTime > :startDT
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
        ];
        if (saConflicts > 0) return false;

        if (userId != null) {
            Integer evtConflicts = [
                SELECT COUNT() FROM Event
                WHERE OwnerId = :userId
                AND StartDateTime < :endDT AND EndDateTime > :startDT
                AND (ShowAs = NULL OR ShowAs != 'Free')
            ];
            if (evtConflicts > 0) return false;
        }

        Integer absConflicts = [
            SELECT COUNT() FROM ResourceAbsence
            WHERE ResourceId = :resourceId
            AND Start < :endDT AND End > :startDT
        ];
        return absConflicts == 0;
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

    private static Map<Id, List<List<DateTime>>> buildBusyMap(
        Set<Id> resourceIds, Map<Id, Id> resourceToUser, Set<Id> territoryIds,
        DateTime rangeStart, DateTime rangeEnd
    ) {
        Map<Id, List<List<DateTime>>> busy = new Map<Id, List<List<DateTime>>>();
        for (Id rId : resourceIds) busy.put(rId, new List<List<DateTime>>());

        List<ServiceAppointment> appts = [
            SELECT Id, SchedStartTime, SchedEndTime FROM ServiceAppointment
            WHERE ServiceTerritoryId IN :territoryIds
            AND SchedStartTime < :rangeEnd AND SchedEndTime > :rangeStart
            AND Status NOT IN ('Canceled','Cannot Complete')
        ];
        if (!appts.isEmpty()) {
            Map<Id, ServiceAppointment> saMap = new Map<Id, ServiceAppointment>(appts);
            for (AssignedResource arec : [
                SELECT ServiceAppointmentId, ServiceResourceId FROM AssignedResource
                WHERE ServiceAppointmentId IN :saMap.keySet()
                AND ServiceResourceId IN :resourceIds
            ]) {
                ServiceAppointment sa = saMap.get(arec.ServiceAppointmentId);
                if (sa != null && busy.containsKey(arec.ServiceResourceId)) {
                    busy.get(arec.ServiceResourceId).add(
                        new List<DateTime>{sa.SchedStartTime, sa.SchedEndTime});
                }
            }
        }

        Set<Id> userIds = new Set<Id>(resourceToUser.values());
        Map<Id, Id> userToResource = new Map<Id, Id>();
        for (Id rId : resourceToUser.keySet()) {
            userToResource.put(resourceToUser.get(rId), rId);
        }
        if (!userIds.isEmpty()) {
            for (Event ev : [
                SELECT OwnerId, StartDateTime, EndDateTime FROM Event
                WHERE OwnerId IN :userIds
                AND StartDateTime < :rangeEnd AND EndDateTime > :rangeStart
                AND (ShowAs = NULL OR ShowAs != 'Free')
            ]) {
                Id rId = userToResource.get(ev.OwnerId);
                if (rId != null && busy.containsKey(rId)) {
                    busy.get(rId).add(new List<DateTime>{ev.StartDateTime, ev.EndDateTime});
                }
            }
        }

        for (ResourceAbsence ra : [
            SELECT ResourceId, Start, End FROM ResourceAbsence
            WHERE ResourceId IN :resourceIds
            AND Start < :rangeEnd AND End > :rangeStart
        ]) {
            if (busy.containsKey(ra.ResourceId)) {
                busy.get(ra.ResourceId).add(new List<DateTime>{ra.Start, ra.End});
            }
        }
        return busy;
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

    private static void tryPut(SObject rec, String f, Object v) {
        try { rec.put(f, v); } catch (Exception ex) { }
    }
}
