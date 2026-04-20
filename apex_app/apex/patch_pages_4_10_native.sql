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
    wwv_flow_imp_page.remove_page(p_flow_id => 100, p_page_id => 4);
    wwv_flow_imp_page.remove_page(p_flow_id => 100, p_page_id => 5);
    wwv_flow_imp_page.remove_page(p_flow_id => 100, p_page_id => 6);
    wwv_flow_imp_page.remove_page(p_flow_id => 100, p_page_id => 7);
    wwv_flow_imp_page.remove_page(p_flow_id => 100, p_page_id => 8);
    wwv_flow_imp_page.remove_page(p_flow_id => 100, p_page_id => 9);
    wwv_flow_imp_page.remove_page(p_flow_id => 100, p_page_id => 10);
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>4
,p_user_interface_id=>1045062637249549896
,p_name=>'Findings Explorer'
,p_alias=>'FINDINGS'
,p_step_title=>'Findings Explorer'
,p_autocomplete_on_off=>'OFF'
,p_page_template_options=>'#DEFAULT#'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>920400000000040001,p_plug_name=>'Findings Explorer',p_icon_css_classes=>'fa-exclamation-triangle',p_region_template_options=>'#DEFAULT#',p_escape_on_http_output=>'Y',p_plug_template=>1044967870434549751,p_plug_display_sequence=>10,p_plug_display_point=>'REGION_POSITION_01',p_attribute_01=>'N',p_attribute_02=>'HTML',p_attribute_03=>'Y');
wwv_flow_imp_page.create_page_plug(
 p_id=>920400000000040002,p_plug_name=>'Controls',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#',p_plug_template=>1044975521009549762,p_plug_display_sequence=>20,p_plug_display_point=>'BODY');
wwv_flow_imp_page.create_page_item(
 p_id=>920400000000040003,p_name=>'P4_RUN_ID',p_item_sequence=>10,p_item_plug_id=>920400000000040002,p_prompt=>'Run ID',p_display_as=>'NATIVE_TEXT_FIELD',p_cSize=>20,p_cMaxlength=>40,p_label_alignment=>'RIGHT',p_field_template=>1045038576799549839,p_item_template_options=>'#DEFAULT#',p_is_persistent=>'N',p_attribute_04=>'TEXT',p_attribute_05=>'NONE');
wwv_flow_imp_page.create_page_button(
 p_id=>920400000000040004,p_flow_step_id=>4,p_button_sequence=>20,p_button_plug_id=>920400000000040002,p_button_name=>'GO',p_button_action=>'SUBMIT',p_button_template_options=>'#DEFAULT#',p_button_template_id=>1045039993493549844,p_button_is_hot=>'Y',p_button_image_alt=>'Go',p_button_position=>'REGION_TEMPLATE_NEXT');
wwv_flow_imp_page.create_page_plug(
 p_id=>920400000000040005,p_plug_name=>'Findings',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders',p_plug_template=>1044975521009549762,p_plug_display_sequence=>30,p_plug_display_point=>'BODY',p_query_type=>'SQL',p_plug_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select metric_domain, metric_name, severity, current_value, prior_mean, prior_sd, n_prior, z_score, pct_delta',
'from awr_trend_findings',
'where run_id = to_number(:P4_RUN_ID)',
'order by case severity when ''CRITICAL'' then 1 when ''WARN'' then 2 else 3 end, abs(nvl(z_score,0)) desc')),p_plug_source_type=>'NATIVE_IR');
wwv_flow_imp_page.create_worksheet(p_id=>920400000000040006,p_max_row_count=>'1000000',p_pagination_type=>'ROWS_X_TO_Y',p_pagination_display_pos=>'BOTTOM_RIGHT',p_report_list_mode=>'TABS',p_lazy_loading=>false,p_show_detail_link=>'N',p_show_notify=>'Y',p_download_formats=>'CSV:HTML:XLSX:PDF',p_enable_mail_download=>'Y',p_owner=>'AWR_APEX');
wwv_flow_imp_page.create_worksheet_column(p_id=>920400000000040007,p_worksheet_id=>920400000000040006,p_db_column_name=>'METRIC_DOMAIN',p_display_order=>10,p_column_identifier=>'A',p_column_label=>'Domain',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920400000000040008,p_worksheet_id=>920400000000040006,p_db_column_name=>'METRIC_NAME',p_display_order=>20,p_column_identifier=>'B',p_column_label=>'Metric',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920400000000040009,p_worksheet_id=>920400000000040006,p_db_column_name=>'SEVERITY',p_display_order=>30,p_column_identifier=>'C',p_column_label=>'Severity',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920400000000040010,p_worksheet_id=>920400000000040006,p_db_column_name=>'CURRENT_VALUE',p_display_order=>40,p_column_identifier=>'D',p_column_label=>'Current',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920400000000040011,p_worksheet_id=>920400000000040006,p_db_column_name=>'PRIOR_MEAN',p_display_order=>50,p_column_identifier=>'E',p_column_label=>'Prior Mean',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920400000000040012,p_worksheet_id=>920400000000040006,p_db_column_name=>'PRIOR_SD',p_display_order=>60,p_column_identifier=>'F',p_column_label=>'Prior SD',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920400000000040013,p_worksheet_id=>920400000000040006,p_db_column_name=>'N_PRIOR',p_display_order=>70,p_column_identifier=>'G',p_column_label=>'History N',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920400000000040014,p_worksheet_id=>920400000000040006,p_db_column_name=>'Z_SCORE',p_display_order=>80,p_column_identifier=>'H',p_column_label=>'Z Score',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920400000000040015,p_worksheet_id=>920400000000040006,p_db_column_name=>'PCT_DELTA',p_display_order=>90,p_column_identifier=>'I',p_column_label=>'% Delta',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_rpt(p_id=>920400000000040016,p_application_user=>'APXWS_DEFAULT',p_report_seq=>10,p_report_alias=>'FINDINGS_DEFAULT',p_status=>'PUBLIC',p_is_default=>'Y',p_report_columns=>'METRIC_DOMAIN:METRIC_NAME:SEVERITY:CURRENT_VALUE:PRIOR_MEAN:PRIOR_SD:N_PRIOR:Z_SCORE:PCT_DELTA');
wwv_flow_imp_page.create_page_process(
 p_id=>920400000000040017,p_flow_step_id=>4,p_process_sequence=>10,p_process_point=>'BEFORE_HEADER',p_process_type=>'NATIVE_PLSQL',p_process_name=>'Default Run',p_process_sql_clob=>wwv_flow_string.join(wwv_flow_t_varchar2('if :P4_RUN_ID is null then','    select max(run_id) into :P4_RUN_ID from awr_trend_runs;','end if;')),p_process_clob_language=>'PLSQL');
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>5,p_user_interface_id=>1045062637249549896,p_name=>'Metrics Dashboard',p_alias=>'METRICS',p_step_title=>'Metrics Dashboard',p_autocomplete_on_off=>'OFF',p_page_template_options=>'#DEFAULT#');
wwv_flow_imp_page.create_page_plug(
 p_id=>920500000000050001,p_plug_name=>'Metrics Dashboard',p_icon_css_classes=>'fa-line-chart',p_region_template_options=>'#DEFAULT#',p_escape_on_http_output=>'Y',p_plug_template=>1044967870434549751,p_plug_display_sequence=>10,p_plug_display_point=>'REGION_POSITION_01',p_attribute_01=>'N',p_attribute_02=>'HTML',p_attribute_03=>'Y');
wwv_flow_imp_page.create_page_plug(
 p_id=>920500000000050002,p_plug_name=>'Controls',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#',p_plug_template=>1044975521009549762,p_plug_display_sequence=>20,p_plug_display_point=>'BODY');
wwv_flow_imp_page.create_page_item(
 p_id=>920500000000050003,p_name=>'P5_RUN_ID',p_item_sequence=>10,p_item_plug_id=>920500000000050002,p_prompt=>'Run ID',p_display_as=>'NATIVE_TEXT_FIELD',p_cSize=>20,p_cMaxlength=>40,p_label_alignment=>'RIGHT',p_field_template=>1045038576799549839,p_item_template_options=>'#DEFAULT#',p_is_persistent=>'N',p_attribute_04=>'TEXT',p_attribute_05=>'NONE');
wwv_flow_imp_page.create_page_item(
 p_id=>920500000000050004,p_name=>'P5_METRIC_DOMAIN',p_item_sequence=>20,p_item_plug_id=>920500000000050002,p_prompt=>'Metric Domain',p_display_as=>'NATIVE_TEXT_FIELD',p_cSize=>20,p_cMaxlength=>20,p_label_alignment=>'RIGHT',p_field_template=>1045038576799549839,p_item_template_options=>'#DEFAULT#',p_is_persistent=>'N',p_attribute_04=>'TEXT',p_attribute_05=>'NONE');
wwv_flow_imp_page.create_page_button(
 p_id=>920500000000050005,p_flow_step_id=>5,p_button_sequence=>30,p_button_plug_id=>920500000000050002,p_button_name=>'GO',p_button_action=>'SUBMIT',p_button_template_options=>'#DEFAULT#',p_button_template_id=>1045039993493549844,p_button_is_hot=>'Y',p_button_image_alt=>'Go',p_button_position=>'REGION_TEMPLATE_NEXT');
wwv_flow_imp_page.create_page_plug(
 p_id=>920500000000050006,p_plug_name=>'Metric Series',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders',p_plug_template=>1044975521009549762,p_plug_display_sequence=>30,p_plug_display_point=>'BODY',p_query_type=>'SQL',p_plug_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select metric_domain, metric_name, week_offset, metric_value, metric_unit',
'from awr_app_metric_series_v',
'where run_id = to_number(:P5_RUN_ID)',
'  and (:P5_METRIC_DOMAIN is null or metric_domain = upper(:P5_METRIC_DOMAIN))',
'order by metric_domain, metric_name, week_offset')),p_plug_source_type=>'NATIVE_IR');
wwv_flow_imp_page.create_worksheet(p_id=>920500000000050007,p_max_row_count=>'1000000',p_pagination_type=>'ROWS_X_TO_Y',p_pagination_display_pos=>'BOTTOM_RIGHT',p_report_list_mode=>'TABS',p_lazy_loading=>false,p_show_detail_link=>'N',p_show_notify=>'Y',p_download_formats=>'CSV:HTML:XLSX:PDF',p_enable_mail_download=>'Y',p_owner=>'AWR_APEX');
wwv_flow_imp_page.create_worksheet_column(p_id=>920500000000050008,p_worksheet_id=>920500000000050007,p_db_column_name=>'METRIC_DOMAIN',p_display_order=>10,p_column_identifier=>'A',p_column_label=>'Domain',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920500000000050009,p_worksheet_id=>920500000000050007,p_db_column_name=>'METRIC_NAME',p_display_order=>20,p_column_identifier=>'B',p_column_label=>'Metric',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920500000000050010,p_worksheet_id=>920500000000050007,p_db_column_name=>'WEEK_OFFSET',p_display_order=>30,p_column_identifier=>'C',p_column_label=>'Week Offset',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920500000000050011,p_worksheet_id=>920500000000050007,p_db_column_name=>'METRIC_VALUE',p_display_order=>40,p_column_identifier=>'D',p_column_label=>'Value',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920500000000050012,p_worksheet_id=>920500000000050007,p_db_column_name=>'METRIC_UNIT',p_display_order=>50,p_column_identifier=>'E',p_column_label=>'Unit',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_rpt(p_id=>920500000000050013,p_application_user=>'APXWS_DEFAULT',p_report_seq=>10,p_report_alias=>'METRICS_DEFAULT',p_status=>'PUBLIC',p_is_default=>'Y',p_report_columns=>'METRIC_DOMAIN:METRIC_NAME:WEEK_OFFSET:METRIC_VALUE:METRIC_UNIT');
wwv_flow_imp_page.create_page_process(
 p_id=>920500000000050014,p_flow_step_id=>5,p_process_sequence=>10,p_process_point=>'BEFORE_HEADER',p_process_type=>'NATIVE_PLSQL',p_process_name=>'Default Run',p_process_sql_clob=>wwv_flow_string.join(wwv_flow_t_varchar2('if :P5_RUN_ID is null then','    select max(run_id) into :P5_RUN_ID from awr_trend_runs;','end if;')),p_process_clob_language=>'PLSQL');
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>6,p_user_interface_id=>1045062637249549896,p_name=>'Waits Dashboard',p_alias=>'WAITS',p_step_title=>'Waits Dashboard',p_autocomplete_on_off=>'OFF',p_page_template_options=>'#DEFAULT#');
wwv_flow_imp_page.create_page_plug(
 p_id=>920600000000060001,p_plug_name=>'Waits Dashboard',p_icon_css_classes=>'fa-clock-o',p_region_template_options=>'#DEFAULT#',p_escape_on_http_output=>'Y',p_plug_template=>1044967870434549751,p_plug_display_sequence=>10,p_plug_display_point=>'REGION_POSITION_01',p_attribute_01=>'N',p_attribute_02=>'HTML',p_attribute_03=>'Y');
wwv_flow_imp_page.create_page_plug(
 p_id=>920600000000060002,p_plug_name=>'Controls',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#',p_plug_template=>1044975521009549762,p_plug_display_sequence=>20,p_plug_display_point=>'BODY');
wwv_flow_imp_page.create_page_item(
 p_id=>920600000000060003,p_name=>'P6_RUN_ID',p_item_sequence=>10,p_item_plug_id=>920600000000060002,p_prompt=>'Run ID',p_display_as=>'NATIVE_TEXT_FIELD',p_cSize=>20,p_cMaxlength=>40,p_label_alignment=>'RIGHT',p_field_template=>1045038576799549839,p_item_template_options=>'#DEFAULT#',p_is_persistent=>'N',p_attribute_04=>'TEXT',p_attribute_05=>'NONE');
wwv_flow_imp_page.create_page_button(
 p_id=>920600000000060004,p_flow_step_id=>6,p_button_sequence=>20,p_button_plug_id=>920600000000060002,p_button_name=>'GO',p_button_action=>'SUBMIT',p_button_template_options=>'#DEFAULT#',p_button_template_id=>1045039993493549844,p_button_is_hot=>'Y',p_button_image_alt=>'Go',p_button_position=>'REGION_TEMPLATE_NEXT');
wwv_flow_imp_page.create_page_plug(
 p_id=>920600000000060005,p_plug_name=>'Wait Events',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders',p_plug_template=>1044975521009549762,p_plug_display_sequence=>30,p_plug_display_point=>'BODY',p_query_type=>'SQL',p_plug_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select scope, week_offset, event_name, wait_class, total_waits, time_waited_us, avg_wait_ms, rank_in_window',
'from awr_trend_waits',
'where run_id = to_number(:P6_RUN_ID)',
'order by scope, week_offset, rank_in_window, event_name')),p_plug_source_type=>'NATIVE_IR');
wwv_flow_imp_page.create_worksheet(p_id=>920600000000060006,p_max_row_count=>'1000000',p_pagination_type=>'ROWS_X_TO_Y',p_pagination_display_pos=>'BOTTOM_RIGHT',p_report_list_mode=>'TABS',p_lazy_loading=>false,p_show_detail_link=>'N',p_show_notify=>'Y',p_download_formats=>'CSV:HTML:XLSX:PDF',p_enable_mail_download=>'Y',p_owner=>'AWR_APEX');
wwv_flow_imp_page.create_worksheet_column(p_id=>920600000000060007,p_worksheet_id=>920600000000060006,p_db_column_name=>'SCOPE',p_display_order=>10,p_column_identifier=>'A',p_column_label=>'Scope',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920600000000060008,p_worksheet_id=>920600000000060006,p_db_column_name=>'WEEK_OFFSET',p_display_order=>20,p_column_identifier=>'B',p_column_label=>'Week Offset',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920600000000060009,p_worksheet_id=>920600000000060006,p_db_column_name=>'EVENT_NAME',p_display_order=>30,p_column_identifier=>'C',p_column_label=>'Event',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920600000000060010,p_worksheet_id=>920600000000060006,p_db_column_name=>'WAIT_CLASS',p_display_order=>40,p_column_identifier=>'D',p_column_label=>'Wait Class',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920600000000060011,p_worksheet_id=>920600000000060006,p_db_column_name=>'TOTAL_WAITS',p_display_order=>50,p_column_identifier=>'E',p_column_label=>'Total Waits',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920600000000060012,p_worksheet_id=>920600000000060006,p_db_column_name=>'TIME_WAITED_US',p_display_order=>60,p_column_identifier=>'F',p_column_label=>'Time Waited (us)',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920600000000060013,p_worksheet_id=>920600000000060006,p_db_column_name=>'AVG_WAIT_MS',p_display_order=>70,p_column_identifier=>'G',p_column_label=>'Avg Wait (ms)',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920600000000060014,p_worksheet_id=>920600000000060006,p_db_column_name=>'RANK_IN_WINDOW',p_display_order=>80,p_column_identifier=>'H',p_column_label=>'Rank',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_rpt(p_id=>920600000000060015,p_application_user=>'APXWS_DEFAULT',p_report_seq=>10,p_report_alias=>'WAITS_DEFAULT',p_status=>'PUBLIC',p_is_default=>'Y',p_report_columns=>'SCOPE:WEEK_OFFSET:EVENT_NAME:WAIT_CLASS:TOTAL_WAITS:TIME_WAITED_US:AVG_WAIT_MS:RANK_IN_WINDOW');
wwv_flow_imp_page.create_page_process(
 p_id=>920600000000060016,p_flow_step_id=>6,p_process_sequence=>10,p_process_point=>'BEFORE_HEADER',p_process_type=>'NATIVE_PLSQL',p_process_name=>'Default Run',p_process_sql_clob=>wwv_flow_string.join(wwv_flow_t_varchar2('if :P6_RUN_ID is null then','    select max(run_id) into :P6_RUN_ID from awr_trend_runs;','end if;')),p_process_clob_language=>'PLSQL');
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>7,p_user_interface_id=>1045062637249549896,p_name=>'Top SQL Explorer',p_alias=>'TOP_SQL',p_step_title=>'Top SQL Explorer',p_autocomplete_on_off=>'OFF',p_page_template_options=>'#DEFAULT#');
wwv_flow_imp_page.create_page_plug(
 p_id=>920700000000070001,p_plug_name=>'Top SQL Explorer',p_icon_css_classes=>'fa-database',p_region_template_options=>'#DEFAULT#',p_escape_on_http_output=>'Y',p_plug_template=>1044967870434549751,p_plug_display_sequence=>10,p_plug_display_point=>'REGION_POSITION_01',p_attribute_01=>'N',p_attribute_02=>'HTML',p_attribute_03=>'Y');
wwv_flow_imp_page.create_page_plug(
 p_id=>920700000000070002,p_plug_name=>'Controls',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#',p_plug_template=>1044975521009549762,p_plug_display_sequence=>20,p_plug_display_point=>'BODY');
wwv_flow_imp_page.create_page_item(
 p_id=>920700000000070003,p_name=>'P7_RUN_ID',p_item_sequence=>10,p_item_plug_id=>920700000000070002,p_prompt=>'Run ID',p_display_as=>'NATIVE_TEXT_FIELD',p_cSize=>20,p_cMaxlength=>40,p_label_alignment=>'RIGHT',p_field_template=>1045038576799549839,p_item_template_options=>'#DEFAULT#',p_is_persistent=>'N',p_attribute_04=>'TEXT',p_attribute_05=>'NONE');
wwv_flow_imp_page.create_page_item(
 p_id=>920700000000070004,p_name=>'P7_DIMENSION',p_item_sequence=>20,p_item_plug_id=>920700000000070002,p_prompt=>'Dimension',p_display_as=>'NATIVE_TEXT_FIELD',p_cSize=>20,p_cMaxlength=>20,p_label_alignment=>'RIGHT',p_field_template=>1045038576799549839,p_item_template_options=>'#DEFAULT#',p_is_persistent=>'N',p_attribute_04=>'TEXT',p_attribute_05=>'NONE');
wwv_flow_imp_page.create_page_button(
 p_id=>920700000000070005,p_flow_step_id=>7,p_button_sequence=>30,p_button_plug_id=>920700000000070002,p_button_name=>'GO',p_button_action=>'SUBMIT',p_button_template_options=>'#DEFAULT#',p_button_template_id=>1045039993493549844,p_button_is_hot=>'Y',p_button_image_alt=>'Go',p_button_position=>'REGION_TEMPLATE_NEXT');
wwv_flow_imp_page.create_page_plug(
 p_id=>920700000000070006,p_plug_name=>'Top SQL',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders',p_plug_template=>1044975521009549762,p_plug_display_sequence=>30,p_plug_display_point=>'BODY',p_query_type=>'SQL',p_plug_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select dimension, week_offset, rank_in_window, sql_id, plan_hash_value, executions_delta, elapsed_time_delta_us, cpu_time_delta_us, buffer_gets_delta, sql_text_short',
'from awr_app_top_sql_v',
'where run_id = to_number(:P7_RUN_ID)',
'  and (:P7_DIMENSION is null or dimension = upper(:P7_DIMENSION))',
'order by dimension, week_offset, rank_in_window')),p_plug_source_type=>'NATIVE_IR');
wwv_flow_imp_page.create_worksheet(p_id=>920700000000070007,p_max_row_count=>'1000000',p_pagination_type=>'ROWS_X_TO_Y',p_pagination_display_pos=>'BOTTOM_RIGHT',p_report_list_mode=>'TABS',p_lazy_loading=>false,p_show_detail_link=>'N',p_show_notify=>'Y',p_download_formats=>'CSV:HTML:XLSX:PDF',p_enable_mail_download=>'Y',p_owner=>'AWR_APEX');
wwv_flow_imp_page.create_worksheet_column(p_id=>920700000000070008,p_worksheet_id=>920700000000070007,p_db_column_name=>'DIMENSION',p_display_order=>10,p_column_identifier=>'A',p_column_label=>'Dimension',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920700000000070009,p_worksheet_id=>920700000000070007,p_db_column_name=>'WEEK_OFFSET',p_display_order=>20,p_column_identifier=>'B',p_column_label=>'Week Offset',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920700000000070010,p_worksheet_id=>920700000000070007,p_db_column_name=>'RANK_IN_WINDOW',p_display_order=>30,p_column_identifier=>'C',p_column_label=>'Rank',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920700000000070011,p_worksheet_id=>920700000000070007,p_db_column_name=>'SQL_ID',p_display_order=>40,p_column_identifier=>'D',p_column_label=>'SQL ID',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920700000000070012,p_worksheet_id=>920700000000070007,p_db_column_name=>'PLAN_HASH_VALUE',p_display_order=>50,p_column_identifier=>'E',p_column_label=>'Plan Hash',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920700000000070013,p_worksheet_id=>920700000000070007,p_db_column_name=>'EXECUTIONS_DELTA',p_display_order=>60,p_column_identifier=>'F',p_column_label=>'Executions',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920700000000070014,p_worksheet_id=>920700000000070007,p_db_column_name=>'ELAPSED_TIME_DELTA_US',p_display_order=>70,p_column_identifier=>'G',p_column_label=>'Elapsed (us)',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920700000000070015,p_worksheet_id=>920700000000070007,p_db_column_name=>'CPU_TIME_DELTA_US',p_display_order=>80,p_column_identifier=>'H',p_column_label=>'CPU (us)',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920700000000070016,p_worksheet_id=>920700000000070007,p_db_column_name=>'BUFFER_GETS_DELTA',p_display_order=>90,p_column_identifier=>'I',p_column_label=>'Buffer Gets',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920700000000070017,p_worksheet_id=>920700000000070007,p_db_column_name=>'SQL_TEXT_SHORT',p_display_order=>100,p_column_identifier=>'J',p_column_label=>'SQL Text',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_rpt(p_id=>920700000000070018,p_application_user=>'APXWS_DEFAULT',p_report_seq=>10,p_report_alias=>'TOPSQL_DEFAULT',p_status=>'PUBLIC',p_is_default=>'Y',p_report_columns=>'DIMENSION:WEEK_OFFSET:RANK_IN_WINDOW:SQL_ID:PLAN_HASH_VALUE:EXECUTIONS_DELTA:ELAPSED_TIME_DELTA_US:CPU_TIME_DELTA_US:BUFFER_GETS_DELTA:SQL_TEXT_SHORT');
wwv_flow_imp_page.create_page_process(
 p_id=>920700000000070019,p_flow_step_id=>7,p_process_sequence=>10,p_process_point=>'BEFORE_HEADER',p_process_type=>'NATIVE_PLSQL',p_process_name=>'Default Run',p_process_sql_clob=>wwv_flow_string.join(wwv_flow_t_varchar2('if :P7_RUN_ID is null then','    select max(run_id) into :P7_RUN_ID from awr_trend_runs;','end if;')),p_process_clob_language=>'PLSQL');
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>8,p_user_interface_id=>1045062637249549896,p_name=>'Targets Admin',p_alias=>'TARGETS',p_step_title=>'Targets',p_autocomplete_on_off=>'OFF',p_page_template_options=>'#DEFAULT#');
wwv_flow_imp_page.create_page_plug(
 p_id=>920800000000080001,p_plug_name=>'Targets',p_icon_css_classes=>'fa-server',p_region_template_options=>'#DEFAULT#',p_escape_on_http_output=>'Y',p_plug_template=>1044967870434549751,p_plug_display_sequence=>10,p_plug_display_point=>'REGION_POSITION_01',p_attribute_01=>'N',p_attribute_02=>'HTML',p_attribute_03=>'Y');
wwv_flow_imp_page.create_page_plug(
 p_id=>920800000000080002,p_plug_name=>'Target Registry',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders',p_plug_template=>1044975521009549762,p_plug_display_sequence=>20,p_plug_display_point=>'BODY',p_query_type=>'SQL',p_plug_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select target_id, target_name, db_link_name, description, default_win_hours, default_weeks_back, default_top_n, default_inst_num, enabled_flag, last_validated_at',
'from awr_app_targets',
'order by target_name')),p_plug_source_type=>'NATIVE_IR');
wwv_flow_imp_page.create_worksheet(p_id=>920800000000080003,p_max_row_count=>'1000000',p_pagination_type=>'ROWS_X_TO_Y',p_pagination_display_pos=>'BOTTOM_RIGHT',p_report_list_mode=>'TABS',p_lazy_loading=>false,p_show_detail_link=>'N',p_show_notify=>'Y',p_download_formats=>'CSV:HTML:XLSX:PDF',p_enable_mail_download=>'Y',p_owner=>'AWR_APEX');
wwv_flow_imp_page.create_worksheet_column(p_id=>920800000000080004,p_worksheet_id=>920800000000080003,p_db_column_name=>'TARGET_ID',p_display_order=>10,p_is_primary_key=>'Y',p_column_identifier=>'A',p_column_label=>'Target ID',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920800000000080005,p_worksheet_id=>920800000000080003,p_db_column_name=>'TARGET_NAME',p_display_order=>20,p_column_identifier=>'B',p_column_label=>'Target',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920800000000080006,p_worksheet_id=>920800000000080003,p_db_column_name=>'DB_LINK_NAME',p_display_order=>30,p_column_identifier=>'C',p_column_label=>'DB Link',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920800000000080007,p_worksheet_id=>920800000000080003,p_db_column_name=>'DESCRIPTION',p_display_order=>40,p_column_identifier=>'D',p_column_label=>'Description',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920800000000080008,p_worksheet_id=>920800000000080003,p_db_column_name=>'DEFAULT_WIN_HOURS',p_display_order=>50,p_column_identifier=>'E',p_column_label=>'Win Hours',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920800000000080009,p_worksheet_id=>920800000000080003,p_db_column_name=>'DEFAULT_WEEKS_BACK',p_display_order=>60,p_column_identifier=>'F',p_column_label=>'Weeks Back',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920800000000080010,p_worksheet_id=>920800000000080003,p_db_column_name=>'DEFAULT_TOP_N',p_display_order=>70,p_column_identifier=>'G',p_column_label=>'Top N',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920800000000080011,p_worksheet_id=>920800000000080003,p_db_column_name=>'DEFAULT_INST_NUM',p_display_order=>80,p_column_identifier=>'H',p_column_label=>'Instance',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920800000000080012,p_worksheet_id=>920800000000080003,p_db_column_name=>'ENABLED_FLAG',p_display_order=>90,p_column_identifier=>'I',p_column_label=>'Enabled',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920800000000080013,p_worksheet_id=>920800000000080003,p_db_column_name=>'LAST_VALIDATED_AT',p_display_order=>100,p_column_identifier=>'J',p_column_label=>'Last Validated',p_column_type=>'DATE',p_tz_dependent=>'Y');
wwv_flow_imp_page.create_worksheet_rpt(p_id=>920800000000080014,p_application_user=>'APXWS_DEFAULT',p_report_seq=>10,p_report_alias=>'TARGETS_DEFAULT',p_status=>'PUBLIC',p_is_default=>'Y',p_report_columns=>'TARGET_ID:TARGET_NAME:DB_LINK_NAME:DESCRIPTION:DEFAULT_WIN_HOURS:DEFAULT_WEEKS_BACK:DEFAULT_TOP_N:DEFAULT_INST_NUM:ENABLED_FLAG:LAST_VALIDATED_AT');
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>9,p_user_interface_id=>1045062637249549896,p_name=>'Schedules Admin',p_alias=>'SCHEDULES',p_step_title=>'Schedules',p_autocomplete_on_off=>'OFF',p_page_template_options=>'#DEFAULT#');
wwv_flow_imp_page.create_page_plug(
 p_id=>920900000000090001,p_plug_name=>'Schedules',p_icon_css_classes=>'fa-calendar',p_region_template_options=>'#DEFAULT#',p_escape_on_http_output=>'Y',p_plug_template=>1044967870434549751,p_plug_display_sequence=>10,p_plug_display_point=>'REGION_POSITION_01',p_attribute_01=>'N',p_attribute_02=>'HTML',p_attribute_03=>'Y');
wwv_flow_imp_page.create_page_plug(
 p_id=>920900000000090002,p_plug_name=>'Schedule Controls',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#',p_plug_template=>1044975521009549762,p_plug_display_sequence=>20,p_plug_display_point=>'BODY');
wwv_flow_imp_page.create_page_button(
 p_id=>920900000000090003,p_flow_step_id=>9,p_button_sequence=>10,p_button_plug_id=>920900000000090002,p_button_name=>'SYNC_SCHEDULES',p_button_action=>'SUBMIT',p_button_template_options=>'#DEFAULT#',p_button_template_id=>1045039993493549844,p_button_is_hot=>'Y',p_button_image_alt=>'Sync Scheduler Jobs',p_button_position=>'REGION_TEMPLATE_NEXT');
wwv_flow_imp_page.create_page_plug(
 p_id=>920900000000090004,p_plug_name=>'Schedules',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders',p_plug_template=>1044975521009549762,p_plug_display_sequence=>30,p_plug_display_point=>'BODY',p_query_type=>'SQL',p_plug_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select schedule_id, target_id, schedule_name, repeat_interval, enabled_flag, scheduler_job_name, last_status, last_run_id, last_started_at, last_finished_at',
'from awr_app_schedules',
'order by target_id, schedule_name')),p_plug_source_type=>'NATIVE_IR');
wwv_flow_imp_page.create_worksheet(p_id=>920900000000090005,p_max_row_count=>'1000000',p_pagination_type=>'ROWS_X_TO_Y',p_pagination_display_pos=>'BOTTOM_RIGHT',p_report_list_mode=>'TABS',p_lazy_loading=>false,p_show_detail_link=>'N',p_show_notify=>'Y',p_download_formats=>'CSV:HTML:XLSX:PDF',p_enable_mail_download=>'Y',p_owner=>'AWR_APEX');
wwv_flow_imp_page.create_worksheet_column(p_id=>920900000000090006,p_worksheet_id=>920900000000090005,p_db_column_name=>'SCHEDULE_ID',p_display_order=>10,p_is_primary_key=>'Y',p_column_identifier=>'A',p_column_label=>'Schedule ID',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920900000000090007,p_worksheet_id=>920900000000090005,p_db_column_name=>'TARGET_ID',p_display_order=>20,p_column_identifier=>'B',p_column_label=>'Target ID',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920900000000090008,p_worksheet_id=>920900000000090005,p_db_column_name=>'SCHEDULE_NAME',p_display_order=>30,p_column_identifier=>'C',p_column_label=>'Schedule',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920900000000090009,p_worksheet_id=>920900000000090005,p_db_column_name=>'REPEAT_INTERVAL',p_display_order=>40,p_column_identifier=>'D',p_column_label=>'Repeat Interval',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920900000000090010,p_worksheet_id=>920900000000090005,p_db_column_name=>'ENABLED_FLAG',p_display_order=>50,p_column_identifier=>'E',p_column_label=>'Enabled',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920900000000090011,p_worksheet_id=>920900000000090005,p_db_column_name=>'SCHEDULER_JOB_NAME',p_display_order=>60,p_column_identifier=>'F',p_column_label=>'Job Name',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920900000000090012,p_worksheet_id=>920900000000090005,p_db_column_name=>'LAST_STATUS',p_display_order=>70,p_column_identifier=>'G',p_column_label=>'Last Status',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>920900000000090013,p_worksheet_id=>920900000000090005,p_db_column_name=>'LAST_RUN_ID',p_display_order=>80,p_column_identifier=>'H',p_column_label=>'Last Run',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>920900000000090014,p_worksheet_id=>920900000000090005,p_db_column_name=>'LAST_STARTED_AT',p_display_order=>90,p_column_identifier=>'I',p_column_label=>'Last Started',p_column_type=>'DATE',p_tz_dependent=>'Y');
wwv_flow_imp_page.create_worksheet_column(p_id=>920900000000090015,p_worksheet_id=>920900000000090005,p_db_column_name=>'LAST_FINISHED_AT',p_display_order=>100,p_column_identifier=>'J',p_column_label=>'Last Finished',p_column_type=>'DATE',p_tz_dependent=>'Y');
wwv_flow_imp_page.create_worksheet_rpt(p_id=>920900000000090016,p_application_user=>'APXWS_DEFAULT',p_report_seq=>10,p_report_alias=>'SCHEDULES_DEFAULT',p_status=>'PUBLIC',p_is_default=>'Y',p_report_columns=>'SCHEDULE_ID:TARGET_ID:SCHEDULE_NAME:REPEAT_INTERVAL:ENABLED_FLAG:SCHEDULER_JOB_NAME:LAST_STATUS:LAST_RUN_ID:LAST_STARTED_AT:LAST_FINISHED_AT');
wwv_flow_imp_page.create_page_process(
 p_id=>920900000000090017,p_flow_step_id=>9,p_process_sequence=>10,p_process_point=>'AFTER_SUBMIT',p_process_type=>'NATIVE_PLSQL',p_process_name=>'Sync Schedules',p_process_sql_clob=>'awr_app_admin_api.sync_schedules;',p_process_clob_language=>'PLSQL',p_error_display_location=>'INLINE_IN_NOTIFICATION',p_process_when_button_id=>920900000000090003);
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>10,p_user_interface_id=>1045062637249549896,p_name=>'Run Log',p_alias=>'RUN_LOG',p_step_title=>'Run Log',p_autocomplete_on_off=>'OFF',p_page_template_options=>'#DEFAULT#');
wwv_flow_imp_page.create_page_plug(
 p_id=>921000000000100001,p_plug_name=>'Run Log',p_icon_css_classes=>'fa-list-alt',p_region_template_options=>'#DEFAULT#',p_escape_on_http_output=>'Y',p_plug_template=>1044967870434549751,p_plug_display_sequence=>10,p_plug_display_point=>'REGION_POSITION_01',p_attribute_01=>'N',p_attribute_02=>'HTML',p_attribute_03=>'Y');
wwv_flow_imp_page.create_page_plug(
 p_id=>921000000000100002,p_plug_name=>'Controls',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#',p_plug_template=>1044975521009549762,p_plug_display_sequence=>20,p_plug_display_point=>'BODY');
wwv_flow_imp_page.create_page_item(
 p_id=>921000000000100003,p_name=>'P10_RUN_ID',p_item_sequence=>10,p_item_plug_id=>921000000000100002,p_prompt=>'Run ID',p_display_as=>'NATIVE_TEXT_FIELD',p_cSize=>20,p_cMaxlength=>40,p_label_alignment=>'RIGHT',p_field_template=>1045038576799549839,p_item_template_options=>'#DEFAULT#',p_is_persistent=>'N',p_attribute_04=>'TEXT',p_attribute_05=>'NONE');
wwv_flow_imp_page.create_page_button(
 p_id=>921000000000100004,p_flow_step_id=>10,p_button_sequence=>20,p_button_plug_id=>921000000000100002,p_button_name=>'GO',p_button_action=>'SUBMIT',p_button_template_options=>'#DEFAULT#',p_button_template_id=>1045039993493549844,p_button_is_hot=>'Y',p_button_image_alt=>'Go',p_button_position=>'REGION_TEMPLATE_NEXT');
wwv_flow_imp_page.create_page_plug(
 p_id=>921000000000100005,p_plug_name=>'Log Entries',p_region_template_options=>'#DEFAULT#',p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders',p_plug_template=>1044975521009549762,p_plug_display_sequence=>30,p_plug_display_point=>'BODY',p_query_type=>'SQL',p_plug_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select log_id, run_id, step_name, log_level, status, message, created_at',
'from awr_app_run_log_v',
'where (:P10_RUN_ID is null or run_id = to_number(:P10_RUN_ID))',
'order by created_at desc, log_id desc')),p_plug_source_type=>'NATIVE_IR');
wwv_flow_imp_page.create_worksheet(p_id=>921000000000100006,p_max_row_count=>'1000000',p_pagination_type=>'ROWS_X_TO_Y',p_pagination_display_pos=>'BOTTOM_RIGHT',p_report_list_mode=>'TABS',p_lazy_loading=>false,p_show_detail_link=>'N',p_show_notify=>'Y',p_download_formats=>'CSV:HTML:XLSX:PDF',p_enable_mail_download=>'Y',p_owner=>'AWR_APEX');
wwv_flow_imp_page.create_worksheet_column(p_id=>921000000000100007,p_worksheet_id=>921000000000100006,p_db_column_name=>'LOG_ID',p_display_order=>10,p_is_primary_key=>'Y',p_column_identifier=>'A',p_column_label=>'Log ID',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>921000000000100008,p_worksheet_id=>921000000000100006,p_db_column_name=>'RUN_ID',p_display_order=>20,p_column_identifier=>'B',p_column_label=>'Run ID',p_column_type=>'NUMBER',p_heading_alignment=>'RIGHT',p_column_alignment=>'RIGHT');
wwv_flow_imp_page.create_worksheet_column(p_id=>921000000000100009,p_worksheet_id=>921000000000100006,p_db_column_name=>'STEP_NAME',p_display_order=>30,p_column_identifier=>'C',p_column_label=>'Step',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>921000000000100010,p_worksheet_id=>921000000000100006,p_db_column_name=>'LOG_LEVEL',p_display_order=>40,p_column_identifier=>'D',p_column_label=>'Level',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>921000000000100011,p_worksheet_id=>921000000000100006,p_db_column_name=>'STATUS',p_display_order=>50,p_column_identifier=>'E',p_column_label=>'Status',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>921000000000100012,p_worksheet_id=>921000000000100006,p_db_column_name=>'MESSAGE',p_display_order=>60,p_column_identifier=>'F',p_column_label=>'Message',p_column_type=>'STRING');
wwv_flow_imp_page.create_worksheet_column(p_id=>921000000000100013,p_worksheet_id=>921000000000100006,p_db_column_name=>'CREATED_AT',p_display_order=>70,p_column_identifier=>'G',p_column_label=>'Created At',p_column_type=>'DATE',p_tz_dependent=>'Y');
wwv_flow_imp_page.create_worksheet_rpt(p_id=>921000000000100014,p_application_user=>'APXWS_DEFAULT',p_report_seq=>10,p_report_alias=>'RUNLOG_DEFAULT',p_status=>'PUBLIC',p_is_default=>'Y',p_report_columns=>'LOG_ID:RUN_ID:STEP_NAME:LOG_LEVEL:STATUS:MESSAGE:CREATED_AT');
wwv_flow_imp_page.create_page_process(
 p_id=>921000000000100015,p_flow_step_id=>10,p_process_sequence=>10,p_process_point=>'BEFORE_HEADER',p_process_type=>'NATIVE_PLSQL',p_process_name=>'Default Run',p_process_sql_clob=>wwv_flow_string.join(wwv_flow_t_varchar2('if :P10_RUN_ID is null then','    select max(run_id) into :P10_RUN_ID from awr_trend_runs;','end if;')),p_process_clob_language=>'PLSQL');
end;
/

begin
    wwv_flow_imp.import_end;
end;
/
