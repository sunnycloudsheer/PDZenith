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

    @InvocableMethod(
        label='Get PD Scheduling Config'
        description='Returns territory, WorkType, and resource for flowTimeslot.'
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

                if (targetTerritoryId == null) {
                    Date today = Date.today();

                    Set<Id> stmResourceIds = isSticky
                        ? new Set<Id>{ anchorResourceId }
                        : (cachedAllResourceIds != null ? getAllResourceIdSet() : new Set<Id>{ anchorResourceId });

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

                    Set<Id> durationMatchTerritories = new Set<Id>();
                    for (ServiceTerritoryMember stm : stmList) {
                        if (stm.ServiceTerritory.Name.contains(durationLabel + ' Min')
                                || stm.ServiceTerritory.Name.contains(durationLabel + '-Min')
                                || stm.ServiceTerritory.Name.contains(durationLabel + 'min')) {
                            durationMatchTerritories.add(stm.ServiceTerritoryId);
                        }
                    }

                    if (isSticky && !durationMatchTerritories.isEmpty()) {
                        for (Id tId : durationMatchTerritories) {
                            targetTerritoryId = tId;
                            break;
                        }
                    } else if (!isSticky && !durationMatchTerritories.isEmpty()) {
                        targetTerritoryId = findTerritoryWithMostSlots(durationMatchTerritories);
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
                        targetTerritoryId = stmList[0].ServiceTerritoryId;
                    }
                }

                if (targetTerritoryId == null) {
                    throw new AuraHandledException('No Service Territory found for the selected Program Director.');
                }

                if (!isSticky && cachedAllResourceIds != null) {
                    ensureAllResourcesInTerritory(targetTerritoryId, getAllResourceIdSet());
                    Id territoryOwnerResourceId = getOriginalTerritoryMember(targetTerritoryId);
                    if (territoryOwnerResourceId != null) {
                        anchorResourceId = territoryOwnerResourceId;
                    }
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
                if (st.OperatingHoursId == null) {
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
                        try {
                            update new ServiceTerritory(Id = targetTerritoryId, OperatingHoursId = stmOH[0].OperatingHoursId);
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
                    res.allResourceIds = (cachedAllResourceIds != null)
                        ? cachedAllResourceIds
                        : String.valueOf(anchorResourceId);
                }

                res.serviceTerritoryId = targetTerritoryId;
                res.workTypeId         = targetWorkTypeId;
                res.primaryResourceId  = anchorResourceId;
                if (isSticky) {
                    List<User> pdUser = [SELECT Name FROM User WHERE Id = :pdUserId LIMIT 1];
                    res.pdDisplayName = pdUser.isEmpty() ? sr.Name : pdUser[0].Name;
                } else {
                    res.pdDisplayName = 'Will be assigned after booking';
                }
                res.success            = true;

            } catch (Exception e) {
                res.success      = false;
                res.errorMessage = e.getMessage();
            }
            results.add(res);
        }
        return results;
    }

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

        for (ServiceTerritoryMember stm : [
            SELECT ServiceResourceId, ServiceTerritoryId, ServiceTerritory.Name
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
        Id      bestId   = null;
        Decimal bestLoad = null;

        for (ServiceResource sr : resources) {
            Set<Id> srTerritories = resourceToTerritories.get(sr.Id);
            if (srTerritories == null || srTerritories.isEmpty()) continue;

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
            if (bestLoad == null || load < bestLoad) {
                bestLoad = load;
                bestId   = sr.Id;
            }
        }
        cachedAllResourceIds = String.join(allIds, ',');
        return bestId;
    }

    private static Id getOriginalTerritoryMember(Id territoryId) {
        try {
            List<ServiceTerritoryMember> stmList = [
                SELECT ServiceResourceId FROM ServiceTerritoryMember
                WHERE ServiceTerritoryId = :territoryId
                AND TerritoryType = 'P'
                ORDER BY CreatedDate ASC LIMIT 1
            ];
            if (!stmList.isEmpty()) return stmList[0].ServiceResourceId;

            stmList = [
                SELECT ServiceResourceId FROM ServiceTerritoryMember
                WHERE ServiceTerritoryId = :territoryId
                ORDER BY CreatedDate ASC LIMIT 1
            ];
            if (!stmList.isEmpty()) return stmList[0].ServiceResourceId;
        } catch (Exception e) { }
        return null;
    }

    private static void ensureAllResourcesInTerritory(Id territoryId, Set<Id> resourceIds) {
        try {
            Date today = Date.today();
            Set<Id> alreadyMembers = new Set<Id>();
            for (ServiceTerritoryMember stm : [
                SELECT ServiceResourceId FROM ServiceTerritoryMember
                WHERE ServiceTerritoryId = :territoryId
                AND ServiceResourceId IN :resourceIds
                AND EffectiveStartDate <= :today
                AND (EffectiveEndDate = NULL OR EffectiveEndDate >= :today)
            ]) {
                alreadyMembers.add(stm.ServiceResourceId);
            }

            List<ServiceTerritoryMember> toInsert = new List<ServiceTerritoryMember>();
            for (Id srId : resourceIds) {
                if (!alreadyMembers.contains(srId)) {
                    toInsert.add(new ServiceTerritoryMember(
                        ServiceTerritoryId = territoryId,
                        ServiceResourceId  = srId,
                        EffectiveStartDate = today,
                        TerritoryType      = 'S'
                    ));
                }
            }
            if (!toInsert.isEmpty()) {
                insert toInsert;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'ensureAllResourcesInTerritory failed: ' + e.getMessage());
        }
    }

    private static Id findTerritoryWithMostSlots(Set<Id> territoryIds) {
        Map<Id, Id> territoryToOH = new Map<Id, Id>();
        for (ServiceTerritory st : [
            SELECT Id, OperatingHoursId FROM ServiceTerritory
            WHERE Id IN :territoryIds AND OperatingHoursId != null
        ]) {
            territoryToOH.put(st.Id, st.OperatingHoursId);
        }
        if (territoryToOH.isEmpty()) return territoryIds.iterator().next();

        Set<Id> ohIds = new Set<Id>(territoryToOH.values());
        Map<Id, Integer> ohSlotCount = new Map<Id, Integer>();
        for (TimeSlot ts : [
            SELECT OperatingHoursId FROM TimeSlot
            WHERE OperatingHoursId IN :ohIds
        ]) {
            Integer cnt = ohSlotCount.containsKey(ts.OperatingHoursId)
                ? ohSlotCount.get(ts.OperatingHoursId) + 1 : 1;
            ohSlotCount.put(ts.OperatingHoursId, cnt);
        }

        Id bestTerritoryId = null;
        Integer bestCount = 0;
        for (Id tId : territoryIds) {
            Id ohId = territoryToOH.get(tId);
            if (ohId == null) continue;
            Integer cnt = ohSlotCount.containsKey(ohId) ? ohSlotCount.get(ohId) : 0;
            if (cnt > bestCount) {
                bestCount = cnt;
                bestTerritoryId = tId;
            }
        }
        return bestTerritoryId != null ? bestTerritoryId : territoryIds.iterator().next();
    }

    private static Set<Id> getAllResourceIdSet() {
        Set<Id> ids = new Set<Id>();
        if (cachedAllResourceIds != null) {
            for (String s : cachedAllResourceIds.split(',')) {
                String trimmed = s.trim();
                if (String.isNotBlank(trimmed)) {
                    ids.add((Id) trimmed);
                }
            }
        }
        return ids;
    }

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
