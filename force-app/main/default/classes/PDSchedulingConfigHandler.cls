public without sharing class PDSchedulingConfigHandler {

    private static final String PD_PROFILE_NAME = 'Program Director';

    public class ConfigRequest {
        @InvocableVariable(required=true label='Opportunity Id')
        public Id opportunityId;

        @InvocableVariable(required=true label='Is Follow-up Call')
        public Boolean isFollowUp;
    }

    public class ConfigResult {
        @InvocableVariable(label='ServiceTerritory Id')
        public Id serviceTerritoryId;

        @InvocableVariable(label='WorkType Id')
        public Id workTypeId;

        @InvocableVariable(label='Primary ServiceResource Id')
        public Id primaryResourceId;

        @InvocableVariable(label='All Resource Ids (comma-separated for filterByResources)')
        public String allResourceIds;

        @InvocableVariable(label='WorkTypeGroup Id')
        public Id workTypeGroupId;

        @InvocableVariable(label='PD Display Name')
        public String pdDisplayName;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    private static String cachedAllResourceIds;
    private static Id cachedBestTerritoryId;
    private static Id cachedBestResourceInTerritory;
    private static Map<Id, Set<Id>> cachedTerritoryToResources;
    private static Map<Id, ServiceResource> cachedResourceMap;

    // Returns territory, work type, and resource set used by flowTimeslot for PD scheduling.
    @InvocableMethod(
        label='Get PD Scheduling Config'
        description='Returns territory, WorkType, and resource for flowTimeslot. Always restricts timeslots to one PD.'
        category='Scheduling'
    )
    public static List<ConfigResult> getSchedulingConfig(List<ConfigRequest> requests) {
        List<ConfigResult> results = new List<ConfigResult>();

        for (ConfigRequest req : requests) {
            ConfigResult res = new ConfigResult();
            try {
                Boolean followUp       = (req.isFollowUp != null && req.isFollowUp);
                Integer targetDuration = followUp ? 30 : 60;
                String  durationLabel  = followUp ? '30' : '60';

                Id anchorResourceId = getStickyResource(req.opportunityId);
                Boolean isSticky = (anchorResourceId != null);
                if (anchorResourceId == null) {
                    anchorResourceId = getLowestLoadResource(targetDuration, durationLabel);
                }
                if (anchorResourceId == null) {
                    throw new AuraHandledException('No active Program Director Service Resource found.');
                }

                ServiceResource sr = [
                    SELECT Id, RelatedRecordId, Name
                    FROM ServiceResource
                    WHERE Id = :anchorResourceId AND IsActive = true LIMIT 1
                ];
                Id pdUserId = sr.RelatedRecordId;

                Id targetTerritoryId = null;
                Id targetWorkTypeId  = null;

                if (isSticky) {
                    List<ServiceTerritory> territories = new List<ServiceTerritory>();
                    try {
                        territories = [
                            SELECT Id, Name, OperatingHoursId
                            FROM ServiceTerritory
                            WHERE Name LIKE :('%' + durationLabel + ' Min%')
                            AND Assigned_Service_Resource__c = :pdUserId
                            AND IsActive = true
                            ORDER BY CreatedDate DESC LIMIT 1
                        ];
                    } catch (Exception e) { }

                    if (!territories.isEmpty()) {
                        targetTerritoryId = territories[0].Id;
                    }
                }

                if (targetTerritoryId == null && !isSticky && cachedBestTerritoryId != null) {
                    targetTerritoryId = cachedBestTerritoryId;
                    if (cachedBestResourceInTerritory != null) {
                        anchorResourceId = cachedBestResourceInTerritory;
                        sr = [
                            SELECT Id, RelatedRecordId, Name
                            FROM ServiceResource
                            WHERE Id = :anchorResourceId AND IsActive = true LIMIT 1
                        ];
                        pdUserId = sr.RelatedRecordId;
                    }
                }

                if (targetTerritoryId == null) {
                    Date today = Date.today();

                    Set<Id> stmResourceIds = new Set<Id>{ anchorResourceId };

                    List<ServiceTerritoryMember> stmList = [
                        SELECT Id, ServiceTerritoryId, TerritoryType, OperatingHoursId,
                               ServiceTerritory.Name, ServiceTerritory.IsActive, ServiceTerritory.OperatingHoursId
                        FROM ServiceTerritoryMember
                        WHERE ServiceResourceId IN :stmResourceIds
                        AND EffectiveStartDate <= :today
                        AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
                        AND ServiceTerritory.IsActive = true
                        ORDER BY CreatedDate ASC
                    ];

                    Map<Id, Id> stmTerritoryToOH = new Map<Id, Id>();
                    for (ServiceTerritoryMember stm : stmList) {
                        Id ohId = stm.ServiceTerritory.OperatingHoursId != null
                            ? stm.ServiceTerritory.OperatingHoursId : stm.OperatingHoursId;
                        if (ohId != null) {
                            stmTerritoryToOH.put(stm.ServiceTerritoryId, ohId);
                        }
                    }
                    Set<Id> stmValidOHIds = new Set<Id>();
                    Set<Id> stmAllOHIds = new Set<Id>(stmTerritoryToOH.values());
                    if (!stmAllOHIds.isEmpty()) {
                        for (TimeSlot ts : [
                            SELECT OperatingHoursId FROM TimeSlot
                            WHERE OperatingHoursId IN :stmAllOHIds LIMIT 200
                        ]) {
                            stmValidOHIds.add(ts.OperatingHoursId);
                        }
                    }
                    Set<Id> territoriesWithOH = new Set<Id>();
                    for (Id tId : stmTerritoryToOH.keySet()) {
                        if (stmValidOHIds.contains(stmTerritoryToOH.get(tId))) {
                            territoriesWithOH.add(tId);
                        }
                    }

                    Set<Id> durationMatchTerritories = new Set<Id>();
                    for (ServiceTerritoryMember stm : stmList) {
                        if (stm.ServiceTerritory.Name.contains(durationLabel + ' Min')
                                || stm.ServiceTerritory.Name.contains(durationLabel + '-Min')
                                || stm.ServiceTerritory.Name.contains(durationLabel + 'min')) {
                            durationMatchTerritories.add(stm.ServiceTerritoryId);
                        }
                    }

                    if (!durationMatchTerritories.isEmpty()) {
                        for (Id tId : durationMatchTerritories) {
                            if (territoriesWithOH.contains(tId)) {
                                targetTerritoryId = tId;
                                break;
                            }
                        }
                        if (targetTerritoryId == null) {
                            for (Id tId : durationMatchTerritories) {
                                targetTerritoryId = tId;
                                break;
                            }
                        }
                    }

                    if (targetTerritoryId == null && !stmList.isEmpty()) {
                        Set<Id> allTerritoryIds = new Set<Id>();
                        for (ServiceTerritoryMember stm : stmList) {
                            allTerritoryIds.add(stm.ServiceTerritoryId);
                        }
                        try {
                            for (ServiceTerritoryWorkType stwt : [
                                SELECT ServiceTerritoryId, WorkTypeId, WorkType.DurationInMinutes
                                FROM ServiceTerritoryWorkType
                                WHERE ServiceTerritoryId IN :allTerritoryIds AND WorkTypeId != null
                                ORDER BY WorkType.DurationInMinutes ASC
                            ]) {
                                if (Integer.valueOf(stwt.WorkType.DurationInMinutes) == targetDuration
                                        && targetTerritoryId == null) {
                                    targetTerritoryId = stwt.ServiceTerritoryId;
                                    targetWorkTypeId  = stwt.WorkTypeId;
                                }
                            }
                        } catch (Exception e) { }
                    }

                    if (targetTerritoryId == null && !stmList.isEmpty()) {
                        for (ServiceTerritoryMember stm : stmList) {
                            if (territoriesWithOH.contains(stm.ServiceTerritoryId)) {
                                targetTerritoryId = stm.ServiceTerritoryId;
                                break;
                            }
                        }
                        if (targetTerritoryId == null) {
                            targetTerritoryId = stmList[0].ServiceTerritoryId;
                        }
                    }
                }

                if (targetTerritoryId == null) {
                    throw new AuraHandledException('No Service Territory found for the selected Program Director.');
                }

                if (targetWorkTypeId == null) {
                    try {
                        for (ServiceTerritoryWorkType stwt : [
                            SELECT WorkTypeId, WorkType.DurationInMinutes
                            FROM ServiceTerritoryWorkType
                            WHERE ServiceTerritoryId = :targetTerritoryId AND WorkTypeId != null
                            ORDER BY WorkType.DurationInMinutes ASC
                        ]) {
                            if (Integer.valueOf(stwt.WorkType.DurationInMinutes) == targetDuration
                                    && targetWorkTypeId == null) {
                                targetWorkTypeId = stwt.WorkTypeId;
                            }
                        }
                    } catch (Exception e) { }

                    if (targetWorkTypeId == null) {
                        try {
                            List<WorkType> wtList = [
                                SELECT Id FROM WorkType
                                WHERE Assigned_Service_Resource__c = :pdUserId
                                AND DurationInMinutes = :targetDuration
                                ORDER BY CreatedDate DESC LIMIT 1
                            ];
                            if (!wtList.isEmpty()) targetWorkTypeId = wtList[0].Id;
                        } catch (Exception e) { }
                    }

                    if (targetWorkTypeId == null) {
                        List<WorkType> byDur = [
                            SELECT Id FROM WorkType
                            WHERE DurationInMinutes = :targetDuration
                            ORDER BY CreatedDate DESC LIMIT 1
                        ];
                        if (!byDur.isEmpty()) targetWorkTypeId = byDur[0].Id;
                    }
                }

                if (targetWorkTypeId == null) {
                    throw new AuraHandledException('No Work Type found for ' + targetDuration + '-minute duration.');
                }

                ServiceTerritory st = [
                    SELECT Id, OperatingHoursId FROM ServiceTerritory
                    WHERE Id = :targetTerritoryId LIMIT 1
                ];
                Boolean needsOH = (st.OperatingHoursId == null);
                if (!needsOH) {
                    List<TimeSlot> tsCheck = [
                        SELECT Id FROM TimeSlot
                        WHERE OperatingHoursId = :st.OperatingHoursId LIMIT 1
                    ];
                    needsOH = tsCheck.isEmpty();
                }
                if (needsOH) {
                    Id recoveredOHId = null;
                    Date today2 = Date.today();
                    List<ServiceTerritoryMember> stmOH = [
                        SELECT OperatingHoursId FROM ServiceTerritoryMember
                        WHERE ServiceTerritoryId = :targetTerritoryId
                        AND OperatingHoursId != null
                        AND EffectiveStartDate <= :today2
                        AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today2)
                        LIMIT 1
                    ];
                    if (!stmOH.isEmpty()) {
                        List<TimeSlot> memberTs = [
                            SELECT Id FROM TimeSlot
                            WHERE OperatingHoursId = :stmOH[0].OperatingHoursId LIMIT 1
                        ];
                        if (!memberTs.isEmpty()) {
                            recoveredOHId = stmOH[0].OperatingHoursId;
                        }
                    }
                    if (recoveredOHId == null) {
                        Set<Id> candidateOHIds = new Set<Id>();
                        for (ServiceTerritory ohT : [
                            SELECT OperatingHoursId FROM ServiceTerritory
                            WHERE OperatingHoursId != null AND IsActive = true
                            ORDER BY CreatedDate DESC LIMIT 20
                        ]) {
                            candidateOHIds.add(ohT.OperatingHoursId);
                        }
                        if (!candidateOHIds.isEmpty()) {
                            for (TimeSlot ts : [
                                SELECT OperatingHoursId FROM TimeSlot
                                WHERE OperatingHoursId IN :candidateOHIds LIMIT 1
                            ]) {
                                recoveredOHId = ts.OperatingHoursId;
                            }
                        }
                    }
                    if (recoveredOHId != null) {
                        try {
                            update new ServiceTerritory(Id = targetTerritoryId, OperatingHoursId = recoveredOHId);
                        } catch (Exception ex) {
                            System.debug(LoggingLevel.WARN, 'Territory OH update failed: ' + ex.getMessage());
                        }
                    }
                }

                try {
                    WorkType wt = [SELECT Id, TimeframeStart FROM WorkType WHERE Id = :targetWorkTypeId LIMIT 1];
                    if (wt.TimeframeStart != null && wt.TimeframeStart > 0) {
                        update new WorkType(Id = targetWorkTypeId, TimeframeStart = 0);
                    }
                } catch (Exception ex) {
                    System.debug(LoggingLevel.WARN, 'WorkType TimeframeStart update failed: ' + ex.getMessage());
                }

                res.workTypeGroupId = ensureWorkTypeGroup(targetWorkTypeId);

                if (isSticky) {
                    res.allResourceIds = String.valueOf(anchorResourceId);
                } else {
                    res.allResourceIds = buildTerritoryResourceIds(
                        targetTerritoryId, anchorResourceId);
                }

                res.serviceTerritoryId = targetTerritoryId;
                res.workTypeId         = targetWorkTypeId;
                res.primaryResourceId  = anchorResourceId;

                List<User> pdUser = [SELECT Name FROM User WHERE Id = :pdUserId LIMIT 1];
                res.pdDisplayName = pdUser.isEmpty() ? sr.Name : pdUser[0].Name;
                res.success       = true;

            } catch (Exception e) {
                res.success      = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

    // Returns the comma-separated resource IDs that are active members of the territory, always including the anchor.
    private static String buildTerritoryResourceIds(Id territoryId, Id anchorResourceId) {
        if (cachedTerritoryToResources != null && cachedTerritoryToResources.containsKey(territoryId)) {
            Set<Id> members = cachedTerritoryToResources.get(territoryId);
            members.add(anchorResourceId);
            List<String> ids = new List<String>();
            for (Id rId : members) ids.add(String.valueOf(rId));
            return String.join(ids, ',');
        }

        Date today = Date.today();
        Set<Id> memberIds = new Set<Id>();
        memberIds.add(anchorResourceId);
        for (ServiceTerritoryMember stm : [
            SELECT ServiceResourceId FROM ServiceTerritoryMember
            WHERE ServiceTerritoryId = :territoryId
            AND ServiceResource.IsActive = true
            AND EffectiveStartDate <= :today
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
        ]) {
            memberIds.add(stm.ServiceResourceId);
        }
        List<String> ids = new List<String>();
        for (Id rId : memberIds) ids.add(String.valueOf(rId));
        return String.join(ids, ',');
    }

    // Returns the sticky PD ServiceResource for the Opportunity, or null if none qualifies.
    private static Id getStickyResource(Id opportunityId) {
        if (opportunityId == null) return null;

        List<Opportunity> opps = [
            SELECT Program_Director__c FROM Opportunity
            WHERE Id = :opportunityId LIMIT 1
        ];
        if (opps.isEmpty() || opps[0].Program_Director__c == null) return null;

        Id pdUserId = opps[0].Program_Director__c;

        List<User> uList = [
            SELECT Id FROM User
            WHERE Id = :pdUserId
            AND Profile.Name = :PD_PROFILE_NAME
            AND IsActive = true LIMIT 1
        ];
        if (uList.isEmpty()) return null;

        List<ServiceResource> srList = [
            SELECT Id FROM ServiceResource
            WHERE RelatedRecordId = :pdUserId AND IsActive = true LIMIT 1
        ];
        return srList.isEmpty() ? null : srList[0].Id;
    }

    // Picks the lowest-load PD resource and caches the best territory and member set for reuse.
    private static Id getLowestLoadResource(Integer targetDuration, String durationLabel) {
        Set<Id> pdUserIds = new Set<Id>();
        for (User u : [
            SELECT Id FROM User
            WHERE Profile.Name = :PD_PROFILE_NAME AND IsActive = true
        ]) {
            pdUserIds.add(u.Id);
        }
        if (pdUserIds.isEmpty()) return null;

        List<ServiceResource> resources = [
            SELECT Id, Appointment_Count__c, Weight__c, RelatedRecordId
            FROM ServiceResource
            WHERE RelatedRecordId IN :pdUserIds AND IsActive = true
            ORDER BY CreatedDate ASC
        ];
        if (resources.isEmpty()) return null;

        Set<Id> allSrIds = new Set<Id>();
        for (ServiceResource sr : resources) allSrIds.add(sr.Id);

        Date today = Date.today();
        Map<Id, Set<Id>> resourceToTerritories = new Map<Id, Set<Id>>();
        Map<Id, String> territoryNameMap = new Map<Id, String>();
        Map<Id, Id> territoryToOHId = new Map<Id, Id>();
        Map<Id, Set<Id>> territoryToResourceIds = new Map<Id, Set<Id>>();

        Map<String, Id> resourceTerritoryToOH = new Map<String, Id>();

        for (ServiceTerritoryMember stm : [
            SELECT ServiceResourceId, ServiceTerritoryId, ServiceTerritory.Name,
                   ServiceTerritory.OperatingHoursId, OperatingHoursId
            FROM ServiceTerritoryMember
            WHERE ServiceResourceId IN :allSrIds
            AND EffectiveStartDate <= :today
            AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
            AND ServiceTerritory.IsActive = true
        ]) {
            if (!resourceToTerritories.containsKey(stm.ServiceResourceId)) {
                resourceToTerritories.put(stm.ServiceResourceId, new Set<Id>());
            }
            resourceToTerritories.get(stm.ServiceResourceId).add(stm.ServiceTerritoryId);
            territoryNameMap.put(stm.ServiceTerritoryId, stm.ServiceTerritory.Name);
            Id ohId = stm.ServiceTerritory.OperatingHoursId != null
                ? stm.ServiceTerritory.OperatingHoursId : stm.OperatingHoursId;
            if (ohId != null) {
                territoryToOHId.put(stm.ServiceTerritoryId, ohId);
            }
            Id memberOH = (stm.OperatingHoursId != null)
                ? stm.OperatingHoursId : stm.ServiceTerritory.OperatingHoursId;
            if (memberOH != null) {
                String key = stm.ServiceResourceId + ':' + stm.ServiceTerritoryId;
                resourceTerritoryToOH.put(key, memberOH);
            }
            if (!territoryToResourceIds.containsKey(stm.ServiceTerritoryId)) {
                territoryToResourceIds.put(stm.ServiceTerritoryId, new Set<Id>());
            }
            territoryToResourceIds.get(stm.ServiceTerritoryId).add(stm.ServiceResourceId);
        }

        cachedTerritoryToResources = territoryToResourceIds;

        Set<Id> allOHIds = new Set<Id>(territoryToOHId.values());
        allOHIds.addAll(resourceTerritoryToOH.values());

        Set<Id> validOHIds = new Set<Id>();
        Map<Id, Integer> ohDayCount = new Map<Id, Integer>();
        if (!allOHIds.isEmpty()) {
            for (AggregateResult ag : [
                SELECT OperatingHoursId, COUNT_DISTINCT(DayOfWeek) dayCount
                FROM TimeSlot
                WHERE OperatingHoursId IN :allOHIds
                GROUP BY OperatingHoursId
            ]) {
                Id agOhId = (Id)ag.get('OperatingHoursId');
                Integer dayCount = (Integer)ag.get('dayCount');
                ohDayCount.put(agOhId, dayCount);
                if (dayCount > 0) {
                    validOHIds.add(agOhId);
                }
            }
        }
        Set<Id> fullyConfiguredOHIds = new Set<Id>();
        for (Id fohId : ohDayCount.keySet()) {
            if (ohDayCount.get(fohId) >= 5) {
                fullyConfiguredOHIds.add(fohId);
            }
        }

        Set<Id> territoriesWithValidOH = new Set<Id>();
        for (Id tId : territoryToOHId.keySet()) {
            if (validOHIds.contains(territoryToOHId.get(tId))) {
                territoriesWithValidOH.add(tId);
            }
        }

        Set<Id> resourcesWithValidOH = new Set<Id>();
        for (Id srId : resourceToTerritories.keySet()) {
            for (Id tId : resourceToTerritories.get(srId)) {
                if (territoriesWithValidOH.contains(tId)) {
                    resourcesWithValidOH.add(srId);
                    break;
                }
            }
        }

        Set<Id> allTerritoryIds = new Set<Id>();
        for (Set<Id> tIds : resourceToTerritories.values()) {
            allTerritoryIds.addAll(tIds);
        }

        Set<Id> matchingTerritories = new Set<Id>();

        for (Id tId : allTerritoryIds) {
            String tName = territoryNameMap.get(tId);
            if (tName != null && (
                tName.contains(durationLabel + ' Min') ||
                tName.contains(durationLabel + '-Min') ||
                tName.contains(durationLabel + 'min')
            )) {
                matchingTerritories.add(tId);
            }
        }

        if (!allTerritoryIds.isEmpty()) {
            try {
                for (ServiceTerritoryWorkType stwt : [
                    SELECT ServiceTerritoryId FROM ServiceTerritoryWorkType
                    WHERE ServiceTerritoryId IN :allTerritoryIds
                    AND WorkType.DurationInMinutes = :targetDuration
                ]) {
                    matchingTerritories.add(stwt.ServiceTerritoryId);
                }
            } catch (Exception e) { }
        }

        if (!allTerritoryIds.isEmpty()) {
            try {
                for (ServiceTerritory stMatch : [
                    SELECT Id FROM ServiceTerritory
                    WHERE Id IN :allTerritoryIds
                    AND Name LIKE :('%' + durationLabel + ' Min%')
                    AND IsActive = true
                ]) {
                    matchingTerritories.add(stMatch.Id);
                }
            } catch (Exception e) { }
        }

        List<String> allIds = new List<String>();
        Id      bestFullId   = null;
        Decimal bestFullLoad = null;
        Id      bestAnyId    = null;
        Decimal bestAnyLoad  = null;

        for (ServiceResource sr : resources) {
            Set<Id> srTerritories = resourceToTerritories.get(sr.Id);
            if (srTerritories == null || srTerritories.isEmpty()) continue;

            if (!resourcesWithValidOH.isEmpty() && !resourcesWithValidOH.contains(sr.Id)) continue;

            if (!matchingTerritories.isEmpty()) {
                Boolean hasMatch = false;
                for (Id tId : srTerritories) {
                    if (matchingTerritories.contains(tId)) {
                        hasMatch = true;
                        break;
                    }
                }
                if (!hasMatch) continue;
            }

            allIds.add(String.valueOf(sr.Id));
            Decimal cnt  = (sr.Appointment_Count__c != null) ? sr.Appointment_Count__c : 0;
            Decimal wt   = (sr.Weight__c != null && sr.Weight__c > 0) ? sr.Weight__c : 1.0;
            Decimal load = cnt / wt;

            if (bestAnyLoad == null || load < bestAnyLoad) {
                bestAnyLoad = load;
                bestAnyId   = sr.Id;
            }
        }

        Id bestId = bestAnyId;
        cachedAllResourceIds = String.join(allIds, ',');

        cachedResourceMap = new Map<Id, ServiceResource>();
        for (ServiceResource sr : resources) {
            cachedResourceMap.put(sr.Id, sr);
        }

        Set<Id> territoriesWithSTWT = new Set<Id>();
        if (!allTerritoryIds.isEmpty()) {
            try {
                for (ServiceTerritoryWorkType stwt : [
                    SELECT ServiceTerritoryId FROM ServiceTerritoryWorkType
                    WHERE ServiceTerritoryId IN :allTerritoryIds
                    AND WorkType.DurationInMinutes = :targetDuration
                ]) {
                    territoriesWithSTWT.add(stwt.ServiceTerritoryId);
                }
            } catch (Exception e) { }
        }

        cachedBestTerritoryId = null;
        cachedBestResourceInTerritory = null;
        Integer bestMemberCount = 0;

        for (Id tId : matchingTerritories) {
            if (!territoriesWithValidOH.contains(tId)) continue;
            if (!territoriesWithSTWT.contains(tId)) continue;
            Set<Id> members = territoryToResourceIds.get(tId);
            Integer count = (members != null) ? members.size() : 0;
            if (count > bestMemberCount) {
                bestMemberCount = count;
                cachedBestTerritoryId = tId;
            }
        }
        if (cachedBestTerritoryId == null) {
            bestMemberCount = 0;
            for (Id tId : matchingTerritories) {
                if (!territoriesWithValidOH.contains(tId)) continue;
                Set<Id> members = territoryToResourceIds.get(tId);
                Integer count = (members != null) ? members.size() : 0;
                if (count > bestMemberCount) {
                    bestMemberCount = count;
                    cachedBestTerritoryId = tId;
                }
            }
        }
        if (cachedBestTerritoryId == null) {
            bestMemberCount = 0;
            for (Id tId : territoriesWithValidOH) {
                Set<Id> members = territoryToResourceIds.get(tId);
                Integer count = (members != null) ? members.size() : 0;
                if (count > bestMemberCount) {
                    bestMemberCount = count;
                    cachedBestTerritoryId = tId;
                }
            }
        }

        if (cachedBestTerritoryId != null) {
            Set<Id> territoryMembers = territoryToResourceIds.get(cachedBestTerritoryId);
            if (territoryMembers != null && !territoryMembers.isEmpty()) {
                Id      bestFullMember     = null;
                Decimal bestFullMemberLoad = null;
                Id      bestAnyMember      = null;
                Decimal bestAnyMemberLoad  = null;

                for (Id memberId : territoryMembers) {
                    ServiceResource memberSR = cachedResourceMap.get(memberId);
                    if (memberSR == null) continue;

                    String memberKey = memberId + ':' + cachedBestTerritoryId;
                    Id memberOHForTerritory = resourceTerritoryToOH.get(memberKey);

                    if (memberOHForTerritory == null) continue;

                    Decimal cnt = (memberSR.Appointment_Count__c != null) ? memberSR.Appointment_Count__c : 0;
                    Decimal wght = (memberSR.Weight__c != null && memberSR.Weight__c > 0) ? memberSR.Weight__c : 1.0;
                    Decimal load = cnt / wght;

                    if (fullyConfiguredOHIds.contains(memberOHForTerritory)) {
                        if (bestFullMemberLoad == null || load < bestFullMemberLoad) {
                            bestFullMemberLoad = load;
                            bestFullMember = memberId;
                        }
                    }
                    if (bestAnyMemberLoad == null || load < bestAnyMemberLoad) {
                        bestAnyMemberLoad = load;
                        bestAnyMember = memberId;
                    }
                }

                cachedBestResourceInTerritory = (bestFullMember != null) ? bestFullMember : bestAnyMember;
            }
        }

        return bestId;
    }

    // Ensures the WorkType has a WorkTypeGroup membership and returns the group Id.
    private static Id ensureWorkTypeGroup(Id workTypeId) {
        try {
            List<WorkTypeGroupMember> existing = [
                SELECT WorkTypeGroupId FROM WorkTypeGroupMember
                WHERE WorkTypeId = :workTypeId LIMIT 1
            ];
            if (!existing.isEmpty()) return existing[0].WorkTypeGroupId;

            List<WorkTypeGroup> groups = [
                SELECT Id FROM WorkTypeGroup
                WHERE IsActive = true
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            Id groupId;
            if (!groups.isEmpty()) {
                groupId = groups[0].Id;
            } else {
                WorkTypeGroup wtg = new WorkTypeGroup();
                wtg.Name      = 'PD Scheduling';
                wtg.GroupType  = 'Default';
                wtg.IsActive   = true;
                insert wtg;
                groupId = wtg.Id;
            }

            WorkTypeGroupMember wtgm = new WorkTypeGroupMember();
            wtgm.WorkTypeGroupId = groupId;
            wtgm.WorkTypeId      = workTypeId;
            insert wtgm;

            return groupId;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'ensureWorkTypeGroup failed: ' + e.getMessage());
            return null;
        }
    }
}
