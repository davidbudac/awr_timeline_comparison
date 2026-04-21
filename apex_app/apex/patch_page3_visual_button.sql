set define off verify off feedback off

begin
    wwv_flow_imp.import_begin(
        p_version_yyyy_mm_dd     => '2024.11.30',
        p_default_workspace_id   => 3747564116264305,
        p_default_application_id => 100,
        p_default_id_offset      => 0,
        p_default_owner          => 'AWR_APEX'
    );
end;
/

begin
    apex_util.set_security_group_id(apex_util.find_security_group_id('AWR_TREND'));
    wwv_flow_imp_page.remove_page(p_flow_id => 100, p_page_id => 3);
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>3
,p_name=>'Run Overview'
,p_alias=>'RUN_OVERVIEW'
,p_step_title=>'Run Overview'
,p_autocomplete_on_off=>'OFF'
,p_page_template_options=>'#DEFAULT#'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>wwv_flow_imp.id(916551405607756949)
,p_plug_name=>'Run Overview'
,p_icon_css_classes=>'fa-dashboard'
,p_region_template_options=>'#DEFAULT#'
,p_escape_on_http_output=>'Y'
,p_plug_template=>wwv_flow_imp.id(1041219276042276699)
,p_plug_display_sequence=>10
,p_plug_display_point=>'REGION_POSITION_01'
,p_attributes=>wwv_flow_t_plugin_attributes(wwv_flow_t_varchar2(
  'expand_shortcuts', 'N',
  'output_as', 'TEXT',
  'show_line_breaks', 'Y')).to_clob
);
wwv_flow_imp_page.create_page_plug(
 p_id=>wwv_flow_imp.id(916551405607756950)
,p_plug_name=>'Controls'
,p_region_template_options=>'#DEFAULT#'
,p_component_template_options=>'#DEFAULT#'
,p_plug_template=>wwv_flow_imp.id(1041226926617276710)
,p_plug_display_sequence=>20
,p_attributes=>wwv_flow_t_plugin_attributes(wwv_flow_t_varchar2(
  'expand_shortcuts', 'N',
  'output_as', 'TEXT',
  'show_line_breaks', 'Y')).to_clob
);
wwv_flow_imp_page.create_page_plug(
 p_id=>wwv_flow_imp.id(916551405607756959)
,p_plug_name=>'Run Summary'
,p_region_template_options=>'#DEFAULT#'
,p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders'
,p_plug_template=>wwv_flow_imp.id(1041226926617276710)
,p_plug_display_sequence=>30
,p_query_type=>'SQL'
,p_plug_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select',
'    run_id,',
'    target_name,',
'    db_name,',
'    status,',
'    target_end_ts,',
'    win_hours,',
'    weeks_back,',
'    top_n,',
'    critical_count,',
'    warn_count,',
'    valid_windows,',
'    skipped_windows,',
'    error_text',
'from awr_app_run_summary_v',
'where run_id = to_number(:P3_RUN_ID)'))
,p_plug_source_type=>'NATIVE_IR'
);
wwv_flow_imp_page.create_worksheet(
 p_id=>wwv_flow_imp.id(916551405607756960)
,p_max_row_count=>'1000000'
,p_pagination_type=>'ROWS_X_TO_Y'
,p_pagination_display_pos=>'BOTTOM_RIGHT'
,p_report_list_mode=>'TABS'
,p_lazy_loading=>false
,p_show_detail_link=>'N'
,p_show_notify=>'Y'
,p_download_formats=>'CSV:HTML:XLSX:PDF'
,p_enable_mail_download=>'Y'
,p_owner=>'AWR_APEX'
,p_internal_uid=>920300000000030012
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756961)
,p_db_column_name=>'RUN_ID'
,p_display_order=>10
,p_is_primary_key=>'Y'
,p_column_identifier=>'A'
,p_column_label=>'Run ID'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756962)
,p_db_column_name=>'TARGET_NAME'
,p_display_order=>20
,p_column_identifier=>'B'
,p_column_label=>'Target'
,p_column_type=>'STRING'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756963)
,p_db_column_name=>'DB_NAME'
,p_display_order=>30
,p_column_identifier=>'C'
,p_column_label=>'Database'
,p_column_type=>'STRING'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756964)
,p_db_column_name=>'STATUS'
,p_display_order=>40
,p_column_identifier=>'D'
,p_column_label=>'Status'
,p_column_type=>'STRING'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756965)
,p_db_column_name=>'TARGET_END_TS'
,p_display_order=>50
,p_column_identifier=>'E'
,p_column_label=>'Target End'
,p_column_type=>'DATE'
,p_tz_dependent=>'Y'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756966)
,p_db_column_name=>'WIN_HOURS'
,p_display_order=>60
,p_column_identifier=>'F'
,p_column_label=>'Window Hours'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756967)
,p_db_column_name=>'WEEKS_BACK'
,p_display_order=>70
,p_column_identifier=>'G'
,p_column_label=>'Weeks Back'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756968)
,p_db_column_name=>'TOP_N'
,p_display_order=>80
,p_column_identifier=>'H'
,p_column_label=>'Top N'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756969)
,p_db_column_name=>'CRITICAL_COUNT'
,p_display_order=>90
,p_column_identifier=>'I'
,p_column_label=>'Critical'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756970)
,p_db_column_name=>'WARN_COUNT'
,p_display_order=>100
,p_column_identifier=>'J'
,p_column_label=>'Warn'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756971)
,p_db_column_name=>'VALID_WINDOWS'
,p_display_order=>110
,p_column_identifier=>'K'
,p_column_label=>'Valid Windows'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756972)
,p_db_column_name=>'SKIPPED_WINDOWS'
,p_display_order=>120
,p_column_identifier=>'L'
,p_column_label=>'Skipped Windows'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756973)
,p_db_column_name=>'ERROR_TEXT'
,p_display_order=>130
,p_column_identifier=>'M'
,p_column_label=>'Error'
,p_column_type=>'STRING'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_rpt(
 p_id=>wwv_flow_imp.id(916551405607756974)
,p_application_user=>'APXWS_DEFAULT'
,p_report_seq=>10
,p_report_alias=>'RUN_OVERVIEW_DEFAULT'
,p_status=>'PUBLIC'
,p_is_default=>'Y'
,p_report_columns=>'RUN_ID:TARGET_NAME:DB_NAME:STATUS:TARGET_END_TS:WIN_HOURS:WEEKS_BACK:TOP_N:CRITICAL_COUNT:WARN_COUNT:VALID_WINDOWS:SKIPPED_WINDOWS:ERROR_TEXT'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>wwv_flow_imp.id(916551405607756975)
,p_plug_name=>'Aligned Windows'
,p_region_template_options=>'#DEFAULT#'
,p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders'
,p_plug_template=>wwv_flow_imp.id(1041226926617276710)
,p_plug_display_sequence=>40
,p_query_type=>'SQL'
,p_plug_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select',
'    week_offset,',
'    win_start_ts,',
'    win_end_ts,',
'    begin_snap_id,',
'    end_snap_id,',
'    valid_flag,',
'    skip_reason',
'from awr_trend_windows',
'where run_id = to_number(:P3_RUN_ID)',
'order by week_offset'))
,p_plug_source_type=>'NATIVE_IR'
);
wwv_flow_imp_page.create_worksheet(
 p_id=>wwv_flow_imp.id(916551405607756976)
,p_max_row_count=>'1000000'
,p_pagination_type=>'ROWS_X_TO_Y'
,p_pagination_display_pos=>'BOTTOM_RIGHT'
,p_report_list_mode=>'TABS'
,p_lazy_loading=>false
,p_show_detail_link=>'N'
,p_show_notify=>'Y'
,p_download_formats=>'CSV:HTML:XLSX:PDF'
,p_enable_mail_download=>'Y'
,p_owner=>'AWR_APEX'
,p_internal_uid=>920300000000030028
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756977)
,p_db_column_name=>'WEEK_OFFSET'
,p_display_order=>10
,p_column_identifier=>'A'
,p_column_label=>'Week Offset'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756978)
,p_db_column_name=>'WIN_START_TS'
,p_display_order=>20
,p_column_identifier=>'B'
,p_column_label=>'Window Start'
,p_column_type=>'DATE'
,p_tz_dependent=>'Y'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756979)
,p_db_column_name=>'WIN_END_TS'
,p_display_order=>30
,p_column_identifier=>'C'
,p_column_label=>'Window End'
,p_column_type=>'DATE'
,p_tz_dependent=>'Y'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756980)
,p_db_column_name=>'BEGIN_SNAP_ID'
,p_display_order=>40
,p_column_identifier=>'D'
,p_column_label=>'Begin Snap'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756981)
,p_db_column_name=>'END_SNAP_ID'
,p_display_order=>50
,p_column_identifier=>'E'
,p_column_label=>'End Snap'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756982)
,p_db_column_name=>'VALID_FLAG'
,p_display_order=>60
,p_column_identifier=>'F'
,p_column_label=>'Valid'
,p_column_type=>'STRING'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>wwv_flow_imp.id(916551405607756983)
,p_db_column_name=>'SKIP_REASON'
,p_display_order=>70
,p_column_identifier=>'G'
,p_column_label=>'Skip Reason'
,p_column_type=>'STRING'
,p_use_as_row_header=>'N'
);
wwv_flow_imp_page.create_worksheet_rpt(
 p_id=>wwv_flow_imp.id(916551405607756984)
,p_application_user=>'APXWS_DEFAULT'
,p_report_seq=>10
,p_report_alias=>'RUN_WINDOWS_DEFAULT'
,p_status=>'PUBLIC'
,p_is_default=>'Y'
,p_report_columns=>'WEEK_OFFSET:WIN_START_TS:WIN_END_TS:BEGIN_SNAP_ID:END_SNAP_ID:VALID_FLAG:SKIP_REASON'
);
wwv_flow_imp_page.create_page_button(
 p_id=>wwv_flow_imp.id(916551405607756952)
,p_button_sequence=>20
,p_button_plug_id=>wwv_flow_imp.id(916551405607756950)
,p_button_name=>'GO'
,p_button_action=>'SUBMIT'
,p_button_template_options=>'#DEFAULT#'
,p_button_is_hot=>'Y'
,p_button_image_alt=>'Go'
,p_button_position=>'REGION_TEMPLATE_NEXT'
);
wwv_flow_imp_page.create_page_button(
 p_id=>wwv_flow_imp.id(916551405607756953)
,p_button_sequence=>30
,p_button_plug_id=>wwv_flow_imp.id(916551405607756950)
,p_button_name=>'RERUN_CURRENT'
,p_button_action=>'SUBMIT'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Run Again'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_condition=>'P3_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>wwv_flow_imp.id(916551405607756954)
,p_button_sequence=>40
,p_button_plug_id=>wwv_flow_imp.id(916551405607756950)
,p_button_name=>'OPEN_FINDINGS'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Findings'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:4:&SESSION.::&DEBUG.::P4_RUN_ID:&P3_RUN_ID.'
,p_button_condition=>'P3_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>wwv_flow_imp.id(916551405607756955)
,p_button_sequence=>50
,p_button_plug_id=>wwv_flow_imp.id(916551405607756950)
,p_button_name=>'OPEN_METRICS'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Metrics'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:5:&SESSION.::&DEBUG.::P5_RUN_ID:&P3_RUN_ID.'
,p_button_condition=>'P3_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>wwv_flow_imp.id(916551405607756956)
,p_button_sequence=>60
,p_button_plug_id=>wwv_flow_imp.id(916551405607756950)
,p_button_name=>'OPEN_WAITS'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Waits'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:6:&SESSION.::&DEBUG.::P6_RUN_ID:&P3_RUN_ID.'
,p_button_condition=>'P3_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>wwv_flow_imp.id(916551405607756957)
,p_button_sequence=>70
,p_button_plug_id=>wwv_flow_imp.id(916551405607756950)
,p_button_name=>'OPEN_TOP_SQL'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Top SQL'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:7:&SESSION.::&DEBUG.::P7_RUN_ID:&P3_RUN_ID.'
,p_button_condition=>'P3_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>wwv_flow_imp.id(916551405607756987)
,p_button_sequence=>75
,p_button_plug_id=>wwv_flow_imp.id(916551405607756950)
,p_button_name=>'OPEN_VISUALIZATIONS'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Visualizations'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:11:&SESSION.::&DEBUG.::P11_RUN_ID:&P3_RUN_ID.'
,p_button_condition=>'P3_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>wwv_flow_imp.id(916551405607756958)
,p_button_sequence=>80
,p_button_plug_id=>wwv_flow_imp.id(916551405607756950)
,p_button_name=>'OPEN_RUN_LOG'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Run Log'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:10:&SESSION.::&DEBUG.::P10_RUN_ID:&P3_RUN_ID.'
,p_button_condition=>'P3_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_item(
 p_id=>wwv_flow_imp.id(916551405607756951)
,p_name=>'P3_RUN_ID'
,p_item_sequence=>10
,p_item_plug_id=>wwv_flow_imp.id(916551405607756950)
,p_prompt=>'Run ID'
,p_display_as=>'NATIVE_TEXT_FIELD'
,p_cSize=>20
,p_cMaxlength=>40
,p_label_alignment=>'RIGHT'
,p_field_template=>wwv_flow_imp.id(1041289982407276787)
,p_item_template_options=>'#DEFAULT#'
,p_is_persistent=>'N'
,p_attributes=>wwv_flow_t_plugin_attributes(wwv_flow_t_varchar2(
  'disabled', 'N',
  'submit_when_enter_pressed', 'N',
  'subtype', 'TEXT',
  'trim_spaces', 'BOTH')).to_clob
);
wwv_flow_imp_page.create_page_process(
 p_id=>wwv_flow_imp.id(916551405607756986)
,p_process_sequence=>20
,p_process_point=>'AFTER_SUBMIT'
,p_process_type=>'NATIVE_PLSQL'
,p_process_name=>'Rerun Current'
,p_process_sql_clob=>wwv_flow_string.join(wwv_flow_t_varchar2(
'declare',
'    l_run awr_app_run_summary_v%rowtype;',
'    l_new_run_id number;',
'begin',
'    select *',
'    into l_run',
'    from awr_app_run_summary_v',
'    where run_id = to_number(:P3_RUN_ID);',
'',
'    l_new_run_id := awr_app_run_api.submit_run(',
'        p_target_id     => l_run.target_id,',
'        p_target_end_ts => l_run.target_end_ts,',
'        p_win_hours     => l_run.win_hours,',
'        p_weeks_back    => l_run.weeks_back,',
'        p_top_n         => l_run.top_n,',
'        p_inst_num      => nvl(l_run.instance_number, 0));',
'',
'    awr_app_run_api.enqueue_run(l_new_run_id);',
'    :P3_RUN_ID := l_new_run_id;',
'end;'))
,p_process_clob_language=>'PLSQL'
,p_error_display_location=>'INLINE_IN_NOTIFICATION'
,p_process_when_button_id=>wwv_flow_imp.id(916551405607756953)
,p_internal_uid=>920300000000030038
);
wwv_flow_imp_page.create_page_process(
 p_id=>wwv_flow_imp.id(916551405607756985)
,p_process_sequence=>10
,p_process_point=>'BEFORE_HEADER'
,p_process_type=>'NATIVE_PLSQL'
,p_process_name=>'Default Run'
,p_process_sql_clob=>wwv_flow_string.join(wwv_flow_t_varchar2(
'if :P3_RUN_ID is null then',
'    select max(run_id) into :P3_RUN_ID from awr_trend_runs;',
'end if;'))
,p_process_clob_language=>'PLSQL'
,p_internal_uid=>920300000000030037
);
end;
/

begin
    wwv_flow_imp.import_end;
end;
/
