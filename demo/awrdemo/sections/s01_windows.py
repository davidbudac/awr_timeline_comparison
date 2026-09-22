"""Twin of sql/01_windows.sql: aligned-windows ribbon, table, and the
rendered (not run) AWR-report SQL*Plus script."""
from __future__ import annotations

from awrdemo.helpers import esc, mon_dd, to_char_fixed, ts_dy_min, ts_min


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 01_windows BEGIN -->']
    weeks_back = w.weeks_back
    slots = weeks_back + 1
    margin, gap = 20, 10
    slot_w = (1000 - 2 * margin) / slots
    box_w = slot_w - gap

    out.append('<section id="windows"><h2>Aligned windows</h2>')
    out.append('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
               'One bar per window. Dimmed = skipped (missing snap, zero-length, '
               'or instance restart) and dropped from the z-score baseline.</p>')
    out.append('<div class="ribbon">'
               '<svg viewBox="0 0 1000 72" preserveAspectRatio="none" role="img" '
               'aria-label="Baseline windows timeline">')
    out.append('<line x1="0" y1="56" x2="1000" y2="56" stroke="var(--rule)" stroke-width="1"/>')

    for win in sorted(w.windows, key=lambda x: -x.week_offset):
        slot_idx = weeks_back - win.week_offset
        x = margin + slot_idx * slot_w + gap / 2
        is_cur = win.week_offset == 0
        box_y = 14 if is_cur else 20
        box_h = 34 if is_cur else 26
        if win.valid_flag == 'Y':
            status = ('valid &middot; snaps ' + str(win.begin_snap_id) + '&rarr;'
                      + str(win.end_snap_id))
        else:
            status = 'skipped'
            if win.skip_reason:
                status += ' &middot; ' + esc(win.skip_reason[:40])
        out.append('<g><title>' + ts_min(win.win_end_ts) + ' &middot; ' + status + '</title>')
        if win.valid_flag == 'Y':
            out.append('<rect x="' + to_char_fixed(x, 1) + '" y="' + str(box_y)
                       + '" width="' + to_char_fixed(box_w, 1) + '" height="' + str(box_h)
                       + '" rx="4" fill="#2563eb" opacity="' + ('1.0' if is_cur else '0.55') + '"/>')
        else:
            out.append('<rect x="' + to_char_fixed(x, 1) + '" y="' + str(box_y)
                       + '" width="' + to_char_fixed(box_w, 1) + '" height="' + str(box_h)
                       + '" rx="4" fill="var(--skip)" fill-opacity="0.18" stroke="var(--skip)"'
                       ' stroke-dasharray="4,3"/>')
        cx = to_char_fixed(x + box_w / 2, 1)
        out.append('<text x="' + cx + '" y="10" text-anchor="middle" font-size="10" '
                   'fill="var(--muted)">' + mon_dd(win.win_end_ts) + '</text>')
        if is_cur:
            out.append('<text x="' + cx + '" y="35" text-anchor="middle" font-size="11" '
                       'font-weight="600" fill="#ffffff">current</text>')
        if win.valid_flag != 'Y':
            out.append('<text x="' + cx + '" y="68" text-anchor="middle" font-size="10" '
                       'fill="var(--muted)">skipped</text>')
        out.append('</g>')

    out.append('</svg></div>')

    out.append('<table id="windows-table">')
    out.append('<thead><tr><th>Window</th>'
               '<th>Window start</th><th>Window end</th>'
               '<th class="num">Begin snap</th><th class="num">End snap</th>'
               '<th>Status</th><th>Detail</th></tr></thead><tbody>')
    for win in sorted(w.windows, key=lambda x: x.week_offset):
        k = win.week_offset
        label = '<b>Current</b>' if k == 0 else '&minus;' + w.offset_labels[k - 1]
        out.append('<tr class="' + ('skip' if win.valid_flag == 'N' else 'ok')
                   + '" data-w="' + str(k) + '">'
                   + '<td>' + label + '</td>'
                   + '<td>' + ts_dy_min(win.win_start_ts) + '</td>'
                   + '<td>' + ts_dy_min(win.win_end_ts) + '</td>'
                   + '<td class="num">' + (str(win.begin_snap_id) if win.begin_snap_id is not None else '&mdash;') + '</td>'
                   + '<td class="num">' + (str(win.end_snap_id) if win.end_snap_id is not None else '&mdash;') + '</td>'
                   + '<td>' + ('<span class="badge ok">valid</span>' if win.valid_flag == 'Y'
                               else '<span class="badge skip">skipped</span>') + '</td>'
                   + '<td>' + esc(win.skip_reason or '') + '</td></tr>')
    out.append('</tbody></table>')

    out.append('<h3>Generate full AWR reports for these windows</h3>')
    out.append('<p style="font-size:12px;color:var(--muted);margin:0 0 6px 0">'
               'Copy into SQL*Plus to spool a standard Oracle AWR report for each '
               'window above (Diagnostic Pack required). Skipped windows are '
               'commented out; swap <code>_HTML</code> for <code>_TEXT</code> in the '
               'call for a plain-text report.</p>')
    out.append('<div class="codewrap" style="position:relative">')
    out.append('<button type="button" class="copy-btn" data-copy="#awr-report-sql">Copy</button>')
    out.append('<pre id="awr-report-sql" class="sql">'
               + esc('-- AWR reports for the compared windows -- generated by awr_timeline_comparison.'))
    out.append(esc('-- Run as a user with EXECUTE on DBMS_WORKLOAD_REPOSITORY (Diagnostic Pack).'))
    out.append(esc('SET PAGESIZE 0 LINESIZE 1500 LONG 1000000 LONGCHUNKSIZE 1000000'))
    out.append(esc('SET TRIMSPOOL ON HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF'))

    inst = w.inst_num
    for win in sorted(w.windows, key=lambda x: x.week_offset):
        k = win.week_offset
        label = 'current' if k == 0 else '-' + w.offset_labels[k - 1]
        out.append('')
        if win.valid_flag == 'Y':
            dbid, b, e = str(win.dbid), str(win.begin_snap_id), str(win.end_snap_id)
            if inst == 0:
                fname = 'awr_' + dbid + '_all_' + b + '_' + e + '.html'
                call = ('SELECT output FROM TABLE(DBMS_WORKLOAD_REPOSITORY.AWR_GLOBAL_REPORT_HTML('
                        + dbid + ', NULL, ' + b + ', ' + e + '));')
            else:
                fname = 'awr_' + dbid + '_inst' + str(inst) + '_' + b + '_' + e + '.html'
                call = ('SELECT output FROM TABLE(DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML('
                        + dbid + ', ' + str(inst) + ', ' + b + ', ' + e + '));')
            out.append(esc('-- ' + label + ': ' + ts_min(win.win_start_ts) + ' -> '
                           + ts_min(win.win_end_ts) + '  (dbid ' + dbid + ', snaps '
                           + b + ' -> ' + e + ')'))
            out.append(esc('SPOOL ' + fname))
            out.append(esc(call))
            out.append(esc('SPOOL OFF'))
        else:
            out.append(esc('-- ' + label + ': ' + ts_min(win.win_start_ts) + ' -> '
                           + ts_min(win.win_end_ts) + '  -- SKIPPED ('
                           + (win.skip_reason or 'no valid snapshot pair') + ')'))

    out.append('</pre>')
    out.append('</div>')
    out.append('</section>')
    out.append('<!-- AWR-SECTION: 01_windows END -->')
    return "\n".join(out)
