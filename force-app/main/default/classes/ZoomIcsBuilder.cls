/**
 * @File Name          : ZoomIcsBuilder.cls
 * @Description        : Builds an RFC-5545 compliant iCalendar (.ics) payload
 *                       for Zoom meeting invites. Supports the full lifecycle:
 *                         - METHOD:REQUEST  for NEW BOOKING or RESCHEDULE
 *                         - METHOD:CANCEL   for CANCELLATION
 *
 *                       Uses UTC (Z-suffix) for DTSTART / DTEND so every
 *                       calendar client (Google, Outlook, Apple) renders the
 *                       event in the RECIPIENT's local timezone automatically.
 *                       No VTIMEZONE block is required with this approach.
 *
 *                       Duplicate prevention is achieved by keeping the UID
 *                       STABLE for the lifetime of the ServiceAppointment
 *                       record, and incrementing SEQUENCE on every reschedule
 *                       / cancel. This is what instructs calendar clients to
 *                       REPLACE the existing event rather than create a new one.
 * @Author             : Amit Yadav
 * @Created On         : April 2026
 */
public class ZoomIcsBuilder {

    public static final String METHOD_REQUEST = 'REQUEST';
    public static final String METHOD_CANCEL  = 'CANCEL';
    /**
     * Used for the host's dedicated email so calendar clients (Gmail / Outlook)
     * auto-add the event to their calendar — METHOD:REQUEST is rejected for
     * organizer-recipients ("Unable to load event") because the standard
     * expects the organizer to already have the event in their own calendar.
     */
    public static final String METHOD_PUBLISH = 'PUBLISH';

    private static final String LINE_ENDING = '\r\n';

    /**
     * Attendee represents one person on the invite (family, parent, counselor).
     */
    public class Attendee {
        public String name;
        public String email;
        /** 'REQ-PARTICIPANT' | 'OPT-PARTICIPANT' | 'CHAIR'. Defaults to REQ-PARTICIPANT. */
        public String role;
        /** 'NEEDS-ACTION' | 'ACCEPTED' | 'DECLINED' | 'TENTATIVE'. Defaults to NEEDS-ACTION. */
        public String partstat;
        /** Whether this attendee should RSVP. Defaults to true. */
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

    /**
     * IcsInput holds all the data needed to produce an .ics payload.
     */
    public class IcsInput {
        /** Stable UID — MUST remain the same across CREATE / UPDATE / CANCEL. */
        public String uid;

        /** 0 for first invite, incremented by 1 for every update / cancel. */
        public Integer sequence;

        /** METHOD_REQUEST or METHOD_CANCEL. */
        public String method;

        /** Event title (e.g. "Initial Call With John Smith"). */
        public String summary;

        /** Description / body of the calendar event (can contain join URL). */
        public String description;

        /** Location — typically the Zoom join URL. */
        public String location;

        /** Meeting start (Apex Datetime is stored/processed as UTC). */
        public Datetime startTime;

        /** Meeting end. */
        public Datetime endTime;

        public String organizerName;
        public String organizerEmail;
        /**
         * SMTP envelope sender, when different from the organizer (org-wide
         * email address relaying on the ES's behalf). Emitted as a SENT-BY
         * parameter on ORGANIZER so calendar clients accept the delegation
         * instead of treating the sender mismatch as a spoof.
         */
        public String organizerSentByEmail;

        public Attendee primaryAttendee;
        public List<Attendee> ccAttendees;
    }

    /**
     * Main entry point. Produces the .ics text.
     *
     * @param  inp  Fully populated IcsInput.
     * @return      RFC-5545 iCalendar body as a String.
     */
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

        // ---- VEVENT ----------------------------------------------------------
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

        // Organizer (with optional SENT-BY when an org-wide address relays
        // the email on the ES's behalf — Gmail / Outlook reject the .ics if
        // the From: domain doesn't match ORGANIZER and no SENT-BY is set).
        String orgLine = 'ORGANIZER;CN=' + escapeParamValue(inp.organizerName);
        if (String.isNotBlank(inp.organizerSentByEmail)
                && inp.organizerSentByEmail.toLowerCase() != (inp.organizerEmail == null ? '' : inp.organizerEmail.toLowerCase())) {
            orgLine += ';SENT-BY="mailto:' + inp.organizerSentByEmail + '"';
        }
        orgLine += ':mailto:' + inp.organizerEmail;
        lines.add(orgLine);

        // Primary attendee
        if (inp.primaryAttendee != null && String.isNotBlank(inp.primaryAttendee.email)) {
            lines.add(buildAttendeeLine(inp.primaryAttendee));
        }

        // CC attendees
        if (inp.ccAttendees != null) {
            for (Attendee a : inp.ccAttendees) {
                if (a != null && String.isNotBlank(a.email)) {
                    lines.add(buildAttendeeLine(a));
                }
            }
        }

        // Outlook / Exchange compatibility properties
        lines.add('X-MICROSOFT-CDO-BUSYSTATUS:' + busyStat);
        lines.add('X-MICROSOFT-CDO-IMPORTANCE:1');
        lines.add('TRANSP:' + transp);

        // 30-minute reminder (only for active events)
        if (!isCancel) {
            lines.add('BEGIN:VALARM');
            lines.add('ACTION:DISPLAY');
            lines.add('DESCRIPTION:Reminder');
            lines.add('TRIGGER:-PT30M');
            lines.add('END:VALARM');
        }

        lines.add('END:VEVENT');
        lines.add('END:VCALENDAR');

        // Join + apply RFC-5545 line folding (max 75 octets per line)
        return foldLines(lines);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

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

    /** Converts an Apex Datetime (UTC) to the iCal UTC format: yyyymmddThhmmssZ */
    private static String toIcsUtc(Datetime d) {
        return d.formatGmt('yyyyMMdd\'T\'HHmmss') + 'Z';
    }

    /**
     * Escape TEXT values per RFC 5545 §3.3.11:
     *   \ -> \\   ,  , -> \,   ,  ; -> \;   , newlines -> \n
     */
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

    /**
     * Parameter values (like CN="Name") have slightly different escaping:
     * remove control chars, replace " with a space. Also strip \r\n.
     */
    private static String escapeParamValue(String s) {
        if (s == null) return '';
        String r = s.replace('"', '\'');
        r = r.replace('\r', ' ').replace('\n', ' ');
        // CN values can contain commas/semicolons without escaping when not quoted,
        // but to be safe we strip them.
        r = r.replace(';', ' ').replace(':', ' ');
        return r;
    }

    /**
     * RFC 5545 line folding: any content line longer than 75 octets MUST be
     * split with CRLF followed by a single whitespace character. We fold
     * conservatively at 73 chars so UTF-8 multibyte chars don't overflow 75.
     */
    private static String foldLines(List<String> lines) {
        final Integer MAX = 73;
        List<String> out = new List<String>();
        for (String line : lines) {
            if (line == null) continue;
            if (line.length() <= MAX) {
                out.add(line);
                continue;
            }
            // fold
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