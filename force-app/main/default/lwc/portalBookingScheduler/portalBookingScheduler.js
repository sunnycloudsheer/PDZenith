import { LightningElement, api, track } from 'lwc';
import getBookingConfig  from '@salesforce/apex/PortalBookingController.getBookingConfig';
import getAvailableSlots from '@salesforce/apex/PortalBookingController.getAvailableSlots';
import bookAppointment   from '@salesforce/apex/PortalBookingController.bookAppointment';

const MONTHS = ['January','February','March','April','May','June',
    'July','August','September','October','November','December'];

export default class PortalBookingScheduler extends LightningElement {

    @api bookingType = '';
    @api contactId = '';
    @api opportunityId = '';
    @api redirectUrl = '';

    @track isLoading = true;
    @track hasFatalError = false;
    @track fatalErrorDetail = '';
    @track currentStep = 1;
    @track isSlotsLoading = false;
    @track isSubmitting = false;

    config = {};
    clientTimezone = 'America/New_York';

    @track calYear = 0;
    @track calMonth = 0;
    @track calendarDays = [];
    @track selectedDate = null;
    availableDateSet = new Set();
    lastAvailableDate = null;

    @track timeSlots = [];
    @track selectedStart = null;
    @track selectedEnd = null;

    @track contactInfo = {};
    @track bookingResult = {};

    connectedCallback() {
        try {
            this.clientTimezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/New_York';
        } catch (_) {}

        if (!this.bookingType) {
            this.bookingType = this._getUrlParam('type') || 'PD';
        }
        if (!this.contactId) {
            this.contactId = this._getUrlParam('contactId') || '';
        }
        if (!this.opportunityId) {
            this.opportunityId = this._getUrlParam('opportunityId') || '';
        }
        this._init();
    }

    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get hasSlots() { return !this.isSlotsLoading && this.timeSlots.length > 0; }
    get noSlotsForDate() { return !this.isSlotsLoading && this.selectedDate && this.timeSlots.length === 0; }
    get noDateSelected() { return !this.selectedDate; }
    get currentMonthLabel() { return `${MONTHS[this.calMonth]} ${this.calYear}`; }
    get headerTitle() {
        const types = { 'PD': 'Program Director Meeting', 'FSS': 'Onboarding Meeting', 'IC': 'Initial Consultation' };
        return `Schedule Your ${types[this.bookingType] || 'Meeting'}`;
    }
    get meetingDuration() {
        return this.config.durationMinutes ? `${this.config.durationMinutes} minutes` : '';
    }

    get prevMonthDisabled() {
        const now = new Date();
        return this.calYear === now.getFullYear() && this.calMonth === now.getMonth();
    }
    get nextMonthDisabled() {
        if (!this.lastAvailableDate) return true;
        return this.calYear > this.lastAvailableDate.getFullYear() ||
            (this.calYear === this.lastAvailableDate.getFullYear()
             && this.calMonth >= this.lastAvailableDate.getMonth());
    }
    get selectedDateLong() {
        if (!this.selectedDate) return '';
        const d = new Date(this.selectedDate + 'T12:00:00');
        return d.toLocaleDateString('en-US', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
    }

    async _init() {
        try {
            const result = await getBookingConfig({
                bookingType: this.bookingType,
                contactId: this.contactId
            });
            if (!result.success) {
                this.hasFatalError = true;
                this.fatalErrorDetail = result.error || 'Configuration error';
                this.isLoading = false;
                return;
            }
            this.config = result;
            this.contactInfo = result.contactInfo || {};

            const dates = result.availableDates || [];
            this.availableDateSet = new Set(dates);
            if (dates.length > 0) {
                this.lastAvailableDate = new Date(dates[dates.length - 1] + 'T12:00:00');
            }
            const now = new Date();
            this.calYear = now.getFullYear();
            this.calMonth = now.getMonth();
            this._buildCalendar();
            this.isLoading = false;
        } catch (err) {
            this.hasFatalError = true;
            this.fatalErrorDetail = err.body ? err.body.message : err.message;
            this.isLoading = false;
        }
    }

    _buildCalendar() {
        const first = new Date(this.calYear, this.calMonth, 1);
        const startDay = first.getDay();
        const daysInMonth = new Date(this.calYear, this.calMonth + 1, 0).getDate();
        const today = new Date();
        today.setHours(0,0,0,0);
        const rows = [];
        let day = 1 - startDay;

        for (let r = 0; r < 6; r++) {
            const week = [];
            for (let c = 0; c < 7; c++, day++) {
                if (day < 1 || day > daysInMonth) {
                    week.push({ key: `e${r}${c}`, label: '', dateStr: '', cls: 'cal-day empty', disabled: true });
                } else {
                    const dt = new Date(this.calYear, this.calMonth, day);
                    const ds = this._toDateStr(dt);
                    const isPast = dt < today;
                    const isAvail = this.availableDateSet.has(ds);
                    const isSel = ds === this.selectedDate;
                    let cls = 'cal-day';
                    if (isPast || !isAvail) cls += ' disabled';
                    if (isSel) cls += ' selected';
                    if (isAvail && !isPast) cls += ' available';
                    week.push({ key: ds, label: String(day), dateStr: ds, cls, disabled: isPast || !isAvail });
                }
            }
            rows.push({ key: `w${r}`, days: week });
            if (day > daysInMonth) break;
        }
        this.calendarDays = rows;
    }

    handlePrevMonth() {
        if (this.calMonth === 0) { this.calMonth = 11; this.calYear--; }
        else { this.calMonth--; }
        this._buildCalendar();
    }
    handleNextMonth() {
        if (this.calMonth === 11) { this.calMonth = 0; this.calYear++; }
        else { this.calMonth++; }
        this._buildCalendar();
    }

    async handleDateClick(event) {
        const ds = event.currentTarget.dataset.date;
        if (!ds || !this.availableDateSet.has(ds)) return;
        this.selectedDate = ds;
        this._buildCalendar();
        this.isSlotsLoading = true;
        this.timeSlots = [];
        this.selectedStart = null;
        this.selectedEnd = null;

        try {
            const slots = await getAvailableSlots({
                bookingType: this.bookingType,
                dateStr: ds
            });
            this.timeSlots = (slots || []).map(s => {
                const st = new Date(s.startUtc);
                const et = new Date(s.endUtc);
                const label = this._formatTime(st) + ' - ' + this._formatTime(et);
                return {
                    key: s.startUtc,
                    label,
                    startUtc: s.startUtc,
                    endUtc: s.endUtc,
                    availableCount: s.availableCount,
                    cls: 'slot-btn'
                };
            });
        } catch (err) {
            this.timeSlots = [];
        }
        this.isSlotsLoading = false;
    }

    handleSlotClick(event) {
        const startUtc = event.currentTarget.dataset.start;
        const endUtc = event.currentTarget.dataset.end;
        this.selectedStart = startUtc;
        this.selectedEnd = endUtc;
        this.timeSlots = this.timeSlots.map(s => ({
            ...s,
            cls: s.startUtc === startUtc ? 'slot-btn selected' : 'slot-btn'
        }));
    }

    async handleBook() {
        if (!this.selectedStart || !this.selectedEnd) return;
        this.isSubmitting = true;

        try {
            const result = await bookAppointment({
                bookingType: this.bookingType,
                contactId: this.contactId,
                opportunityId: this.opportunityId,
                startTimeISO: this.selectedStart,
                endTimeISO: this.selectedEnd,
                clientTimezone: this.clientTimezone
            });

            if (result.success === 'true') {
                this.bookingResult = result;
                this.currentStep = 2;
            } else {
                this.fatalErrorDetail = result.error || 'Booking failed';
                this.hasFatalError = true;
            }
        } catch (err) {
            this.fatalErrorDetail = err.body ? err.body.message : err.message;
            this.hasFatalError = true;
        }
        this.isSubmitting = false;
    }

    _formatTime(dt) {
        return dt.toLocaleTimeString('en-US', {
            hour: 'numeric', minute: '2-digit', hour12: true,
            timeZone: this.clientTimezone
        });
    }

    _toDateStr(dt) {
        const y = dt.getFullYear();
        const m = String(dt.getMonth() + 1).padStart(2, '0');
        const d = String(dt.getDate()).padStart(2, '0');
        return `${y}-${m}-${d}`;
    }

    _getUrlParam(name) {
        try {
            const url = new URL(window.location.href);
            return url.searchParams.get(name) || '';
        } catch (_) { return ''; }
    }
}
