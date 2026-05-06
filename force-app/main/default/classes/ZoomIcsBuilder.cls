// Builds an RFC-5545 compliant iCalendar (.ics) payload for Zoom meeting invites (REQUEST/CANCEL/PUBLISH).
public without sharing class ZoomIcsBuilder {

    public static final String METHOD_REQUEST = 'REQUEST';
    public static final String METHOD_CANCEL  = 'CANCEL';
    public static final String METHOD_PUBLISH = 'PUBLISH';

    private static final String LINE_ENDING = '\r\n';

    // Represents one person on the invite (family, parent, counselor).
    public class Attendee {
        public String name;
        public String email;
        public String role;
        public String partstat;
        public Boolean rsvp;

        public Attendee(String name, String email, String role) {
            this(name, email, role, null, null);
        }

        public Attendee(String name, String email, String role, String partstat, Boolean rsvp) {
            this.name     = name;
            this.email    = email;
            this.role     = String.isBlank(role) ? 'REQ-PARTICIPANT' : role;
            this.partstat = String.isBlank(partstat) ? 'NEEDS-ACTION' : partstat;
            this.rsvp     = (rsvp == null) ? true : rsvp;
        }
    }

    // Holds all the data needed to produce an .ics payload.
    public class IcsInput {
        public String uid;

        public Integer sequence;

        public String method;

        public String summary;

        public String description;

        public String location;

        public Datetime startTime;

        public Datetime endTime;

        public String organizerName;
        public String organizerEmail;
        public String organizerSentByEmail;

        public Attendee primaryAttendee;
        public List<Attendee> ccAttendees;
    }

    // Main entry point: produces the RFC-5545 iCalendar text from an IcsInput.
    public static String build(IcsInput inp) {
        validate(inp);

        Boolean isCancel = (inp.method == METHOD_CANCEL);
        String status    = isCancel ? 'CANCELLED' : 'CONFIRMED';
        String transp    = isCancel ? 'TRANSPARENT' : 'OPAQUE';
        String busyStat  = isCancel ? 'FREE' : 'BUSY';

        List<String> lines = new List<String>();
        lines.add('BEGIN:VCALENDAR');
        lines.add('VERSION:2.0');
        lines.add('PRODID:-//Zenith Prep Academy//Meeting Scheduler//EN');
        lines.add('CALSCALE:GREGORIAN');
        lines.add('METHOD:' + inp.method);

        lines.add('BEGIN:VEVENT');
        lines.add('UID:' + inp.uid);
        lines.add('SEQUENCE:' + String.valueOf(inp.sequence));
        lines.add('STATUS:' + status);
        lines.add('DTSTAMP:' + toIcsUtc(Datetime.now()));
        lines.add('DTSTART:' + toIcsUtc(inp.startTime));
        lines.add('DTEND:'   + toIcsUtc(inp.endTime));
        lines.add('SUMMARY:' + escapeText(inp.summary));
        if (String.isNotBlank(inp.description)) {
            lines.add('DESCRIPTION:' + escapeText(inp.description));
        }
        if (String.isNotBlank(inp.location)) {
            lines.add('LOCATION:' + escapeText(inp.location));
        }

        String orgLine = 'ORGANIZER;CN=' + escapeParamValue(inp.organizerName);
        if (String.isNotBlank(inp.organizerSentByEmail)
                && inp.organizerSentByEmail.toLowerCase() != (inp.organizerEmail == null ? '' : inp.organizerEmail.toLowerCase())) {
            orgLine += ';SENT-BY="mailto:' + inp.organizerSentByEmail + '"';
        }
        orgLine += ':mailto:' + inp.organizerEmail;
        lines.add(orgLine);

        if (inp.primaryAttendee != null && String.isNotBlank(inp.primaryAttendee.email)) {
            lines.add(buildAttendeeLine(inp.primaryAttendee));
        }

        if (inp.ccAttendees != null) {
            for (Attendee a : inp.ccAttendees) {
                if (a != null && String.isNotBlank(a.email)) {
                    lines.add(buildAttendeeLine(a));
                }
            }
        }

        lines.add('X-MICROSOFT-CDO-BUSYSTATUS:' + busyStat);
        lines.add('X-MICROSOFT-CDO-IMPORTANCE:1');
        lines.add('TRANSP:' + transp);

        if (!isCancel) {
            lines.add('BEGIN:VALARM');
            lines.add('ACTION:DISPLAY');
            lines.add('DESCRIPTION:Reminder');
            lines.add('TRIGGER:-PT30M');
            lines.add('END:VALARM');
        }

        lines.add('END:VEVENT');
        lines.add('END:VCALENDAR');

        return foldLines(lines);
    }

    private static void validate(IcsInput inp) {
        if (inp == null) {
            throw new ZoomIcsBuilderException('IcsInput cannot be null');
        }
        if (String.isBlank(inp.uid)) {
            throw new ZoomIcsBuilderException('UID is required');
        }
        if (inp.sequence == null || inp.sequence < 0) {
            inp.sequence = 0;
        }
        if (String.isBlank(inp.method)) {
            inp.method = METHOD_REQUEST;
        }
        if (inp.method != METHOD_REQUEST
                && inp.method != METHOD_CANCEL
                && inp.method != METHOD_PUBLISH) {
            throw new ZoomIcsBuilderException('Unsupported METHOD: ' + inp.method);
        }
        if (inp.startTime == null || inp.endTime == null) {
            throw new ZoomIcsBuilderException('startTime and endTime are required');
        }
        if (String.isBlank(inp.summary)) {
            inp.summary = 'Meeting';
        }
        if (String.isBlank(inp.organizerEmail)) {
            throw new ZoomIcsBuilderException('organizerEmail is required');
        }
        if (String.isBlank(inp.organizerName)) {
            inp.organizerName = inp.organizerEmail;
        }
    }

    private static String buildAttendeeLine(Attendee a) {
        String partstat = String.isBlank(a.partstat) ? 'NEEDS-ACTION' : a.partstat;
        Boolean rsvp = (a.rsvp == null) ? true : a.rsvp;
        return 'ATTENDEE;CN=' + escapeParamValue(String.isBlank(a.name) ? a.email : a.name)
             + ';RSVP=' + (rsvp ? 'TRUE' : 'FALSE')
             + ';PARTSTAT=' + partstat
             + ';ROLE=' + a.role
             + ';CUTYPE=INDIVIDUAL:mailto:' + a.email;
    }

    // Converts an Apex Datetime (UTC) to the iCal UTC format yyyymmddThhmmssZ.
    private static String toIcsUtc(Datetime d) {
        return d.formatGmt('yyyyMMdd\'T\'HHmmss') + 'Z';
    }

    // Escapes TEXT values per RFC 5545 section 3.3.11.
    private static String escapeText(String s) {
        if (s == null) return '';
        String r = s.replace('\\', '\\\\');
        r = r.replace(';', '\\;');
        r = r.replace(',', '\\,');
        r = r.replace('\r\n', '\\n');
        r = r.replace('\n', '\\n');
        r = r.replace('\r', '\\n');
        return r;
    }

    // Escapes parameter values (e.g. CN="Name") by stripping quotes and control chars.
    private static String escapeParamValue(String s) {
        if (s == null) return '';
        String r = s.replace('"', '\'');
        r = r.replace('\r', ' ').replace('\n', ' ');
        r = r.replace(';', ' ').replace(':', ' ');
        return r;
    }

    // Applies RFC 5545 line folding (max 75 octets per content line).
    private static String foldLines(List<String> lines) {
        final Integer MAX = 73;
        List<String> out = new List<String>();
        for (String line : lines) {
            if (line == null) continue;
            if (line.length() <= MAX) {
                out.add(line);
                continue;
            }
            Integer i = 0;
            out.add(line.substring(0, MAX));
            i = MAX;
            while (i < line.length()) {
                Integer endIdx = Math.min(i + (MAX - 1), line.length());
                out.add(' ' + line.substring(i, endIdx));
                i = endIdx;
            }
        }
        return String.join(out, LINE_ENDING) + LINE_ENDING;
    }

    public class ZoomIcsBuilderException extends Exception {}
}