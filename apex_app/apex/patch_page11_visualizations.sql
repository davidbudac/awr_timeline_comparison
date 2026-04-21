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
    for r in (
        select 1
        from apex_application_pages
        where application_id = 100
          and page_id = 11
    ) loop
        wwv_flow_imp_page.remove_page(p_flow_id => 100, p_page_id => 11);
    end loop;
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>11
,p_name=>'Run Visualizations'
,p_alias=>'RUN_VISUALIZATIONS'
,p_step_title=>'Run Visualizations'
,p_autocomplete_on_off=>'OFF'
,p_page_template_options=>'#DEFAULT#'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>921100000000110001
,p_plug_name=>'Run Visualizations'
,p_icon_css_classes=>'fa-area-chart'
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
 p_id=>921100000000110002
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
wwv_flow_imp_page.create_page_item(
 p_id=>921100000000110003
,p_name=>'P11_RUN_ID'
,p_item_sequence=>10
,p_item_plug_id=>921100000000110002
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
wwv_flow_imp_page.create_page_button(
 p_id=>921100000000110004
,p_button_sequence=>20
,p_button_plug_id=>921100000000110002
,p_button_name=>'GO'
,p_button_action=>'SUBMIT'
,p_button_template_options=>'#DEFAULT#'
,p_button_is_hot=>'Y'
,p_button_image_alt=>'Go'
,p_button_position=>'REGION_TEMPLATE_NEXT'
);
wwv_flow_imp_page.create_page_button(
 p_id=>921100000000110005
,p_button_sequence=>30
,p_button_plug_id=>921100000000110002
,p_button_name=>'OPEN_OVERVIEW'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Run Overview'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:3:&SESSION.::&DEBUG.::P3_RUN_ID:&P11_RUN_ID.'
,p_button_condition=>'P11_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>921100000000110006
,p_button_sequence=>40
,p_button_plug_id=>921100000000110002
,p_button_name=>'OPEN_FINDINGS'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Findings'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:4:&SESSION.::&DEBUG.::P4_RUN_ID:&P11_RUN_ID.'
,p_button_condition=>'P11_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>921100000000110007
,p_button_sequence=>50
,p_button_plug_id=>921100000000110002
,p_button_name=>'OPEN_METRICS'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Metrics'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:5:&SESSION.::&DEBUG.::P5_RUN_ID:&P11_RUN_ID.'
,p_button_condition=>'P11_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>921100000000110008
,p_button_sequence=>60
,p_button_plug_id=>921100000000110002
,p_button_name=>'OPEN_WAITS'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Waits'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:6:&SESSION.::&DEBUG.::P6_RUN_ID:&P11_RUN_ID.'
,p_button_condition=>'P11_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>921100000000110009
,p_button_sequence=>70
,p_button_plug_id=>921100000000110002
,p_button_name=>'OPEN_TOP_SQL'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Top SQL'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:7:&SESSION.::&DEBUG.::P7_RUN_ID:&P11_RUN_ID.'
,p_button_condition=>'P11_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_button(
 p_id=>921100000000110010
,p_button_sequence=>80
,p_button_plug_id=>921100000000110002
,p_button_name=>'OPEN_RUN_LOG'
,p_button_action=>'REDIRECT_PAGE'
,p_button_template_options=>'#DEFAULT#'
,p_button_image_alt=>'Run Log'
,p_button_position=>'REGION_TEMPLATE_NEXT'
,p_button_redirect_url=>'f?p=&APP_ID.:10:&SESSION.::&DEBUG.::P10_RUN_ID:&P11_RUN_ID.'
,p_button_condition=>'P11_RUN_ID'
,p_button_condition_type=>'ITEM_IS_NOT_NULL'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>921100000000110011
,p_plug_name=>'Findings By Domain'
,p_region_template_options=>'#DEFAULT#'
,p_component_template_options=>'#DEFAULT#'
,p_plug_template=>wwv_flow_imp.id(1041226926617276710)
,p_plug_display_sequence=>30
,p_ajax_items_to_submit=>'P11_RUN_ID'
,p_plug_source_type=>'NATIVE_JET_CHART'
);
wwv_flow_imp_page.create_jet_chart(
 p_id=>921100000000110012
,p_region_id=>921100000000110011
,p_chart_type=>'bar'
,p_title=>'Findings by Domain'
,p_height=>'320'
,p_orientation=>'vertical'
,p_legend_rendered=>'off'
,p_tooltip_rendered=>'Y'
,p_show_value=>true
,p_no_data_found_message=>'No findings available for this run.'
);
wwv_flow_imp_page.create_jet_chart_series(
 p_id=>921100000000110013
,p_chart_id=>921100000000110012
,p_seq=>10
,p_name=>'Finding Count'
,p_data_source_type=>'SQL'
,p_data_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select metric_domain as label,',
'       count(*) as value',
'from awr_trend_findings',
'where run_id = to_number(:P11_RUN_ID)',
'group by metric_domain',
'order by metric_domain'))
,p_ajax_items_to_submit=>'P11_RUN_ID'
,p_series_type=>'bar'
,p_items_value_column_name=>'VALUE'
,p_group_name_column_name=>'LABEL'
,p_items_label_rendered=>true
);
wwv_flow_imp_page.create_jet_chart_axis(
 p_id=>921100000000110014
,p_chart_id=>921100000000110012
,p_axis=>'x'
,p_is_rendered=>'on'
,p_title=>'Domain'
);
wwv_flow_imp_page.create_jet_chart_axis(
 p_id=>921100000000110015
,p_chart_id=>921100000000110012
,p_axis=>'y'
,p_is_rendered=>'on'
,p_title=>'Finding Count'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>921100000000110016
,p_plug_name=>'Window Health'
,p_region_template_options=>'#DEFAULT#'
,p_component_template_options=>'#DEFAULT#'
,p_plug_template=>wwv_flow_imp.id(1041226926617276710)
,p_plug_display_sequence=>40
,p_ajax_items_to_submit=>'P11_RUN_ID'
,p_plug_source_type=>'NATIVE_JET_CHART'
);
wwv_flow_imp_page.create_jet_chart(
 p_id=>921100000000110017
,p_region_id=>921100000000110016
,p_chart_type=>'bar'
,p_title=>'Aligned Window Health'
,p_height=>'320'
,p_orientation=>'vertical'
,p_legend_rendered=>'off'
,p_tooltip_rendered=>'Y'
,p_show_value=>true
,p_no_data_found_message=>'No window alignment data available for this run.'
);
wwv_flow_imp_page.create_jet_chart_series(
 p_id=>921100000000110018
,p_chart_id=>921100000000110017
,p_seq=>10
,p_name=>'Window Count'
,p_data_source_type=>'SQL'
,p_data_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select case when valid_flag = ''Y'' then ''Valid'' else ''Skipped'' end as label,',
'       count(*) as value',
'from awr_trend_windows',
'where run_id = to_number(:P11_RUN_ID)',
'group by case when valid_flag = ''Y'' then ''Valid'' else ''Skipped'' end',
'order by 1'))
,p_ajax_items_to_submit=>'P11_RUN_ID'
,p_series_type=>'bar'
,p_items_value_column_name=>'VALUE'
,p_group_name_column_name=>'LABEL'
,p_items_label_rendered=>true
);
wwv_flow_imp_page.create_jet_chart_axis(
 p_id=>921100000000110019
,p_chart_id=>921100000000110017
,p_axis=>'x'
,p_is_rendered=>'on'
,p_title=>'Window State'
);
wwv_flow_imp_page.create_jet_chart_axis(
 p_id=>921100000000110020
,p_chart_id=>921100000000110017
,p_axis=>'y'
,p_is_rendered=>'on'
,p_title=>'Window Count'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>921100000000110021
,p_plug_name=>'Key Load Trend'
,p_region_template_options=>'#DEFAULT#'
,p_component_template_options=>'#DEFAULT#'
,p_plug_template=>wwv_flow_imp.id(1041226926617276710)
,p_plug_display_sequence=>50
,p_ajax_items_to_submit=>'P11_RUN_ID'
,p_plug_source_type=>'NATIVE_JET_CHART'
);
wwv_flow_imp_page.create_jet_chart(
 p_id=>921100000000110022
,p_region_id=>921100000000110021
,p_chart_type=>'line'
,p_title=>'Key Load Trend'
,p_height=>'360'
,p_orientation=>'vertical'
,p_legend_rendered=>'on'
,p_tooltip_rendered=>'Y'
,p_connect_nulls=>'N'
,p_no_data_found_message=>'No load profile data available for this run.'
);
wwv_flow_imp_page.create_jet_chart_series(
 p_id=>921100000000110023
,p_chart_id=>921100000000110022
,p_seq=>10
,p_name=>'Key Load Metrics'
,p_data_source_type=>'SQL'
,p_data_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select case week_offset',
'         when 0 then ''Current''',
'         else to_char(week_offset) || '' week(s) back''',
'       end as week_label,',
'       metric_name,',
'       round(metric_value, 2) as metric_value',
'from awr_app_metric_series_v',
'where run_id = to_number(:P11_RUN_ID)',
'  and metric_domain = ''LOAD''',
'  and metric_name in (''DB time'', ''DB CPU'', ''session logical reads'', ''execute count'')',
'order by week_offset, metric_name'))
,p_ajax_items_to_submit=>'P11_RUN_ID'
,p_series_type=>'line'
,p_series_name_column_name=>'METRIC_NAME'
,p_items_value_column_name=>'METRIC_VALUE'
,p_group_name_column_name=>'WEEK_LABEL'
,p_marker_rendered=>'on'
);
wwv_flow_imp_page.create_jet_chart_axis(
 p_id=>921100000000110024
,p_chart_id=>921100000000110022
,p_axis=>'x'
,p_is_rendered=>'on'
,p_title=>'Comparison Window'
);
wwv_flow_imp_page.create_jet_chart_axis(
 p_id=>921100000000110025
,p_chart_id=>921100000000110022
,p_axis=>'y'
,p_is_rendered=>'on'
,p_title=>'Value Per Second'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>921100000000110026
,p_plug_name=>'Wait Class Trend'
,p_region_template_options=>'#DEFAULT#'
,p_component_template_options=>'#DEFAULT#'
,p_plug_template=>wwv_flow_imp.id(1041226926617276710)
,p_plug_display_sequence=>60
,p_ajax_items_to_submit=>'P11_RUN_ID'
,p_plug_source_type=>'NATIVE_JET_CHART'
);
wwv_flow_imp_page.create_jet_chart(
 p_id=>921100000000110027
,p_region_id=>921100000000110026
,p_chart_type=>'bar'
,p_title=>'Wait Class Trend'
,p_height=>'380'
,p_orientation=>'vertical'
,p_stack=>'on'
,p_legend_rendered=>'on'
,p_tooltip_rendered=>'Y'
,p_show_value=>false
,p_no_data_found_message=>'No wait class data available for this run.'
);
wwv_flow_imp_page.create_jet_chart_series(
 p_id=>921100000000110028
,p_chart_id=>921100000000110027
,p_seq=>10
,p_name=>'Wait Classes'
,p_data_source_type=>'SQL'
,p_data_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select case week_offset',
'         when 0 then ''Current''',
'         else to_char(week_offset) || '' week(s) back''',
'       end as week_label,',
'       wait_class,',
'       round(sum(time_waited_us) / 1e6, 2) as seconds_waited',
'from awr_trend_waits',
'where run_id = to_number(:P11_RUN_ID)',
'  and scope = ''CLASS''',
'group by week_offset, wait_class',
'order by week_offset, wait_class'))
,p_ajax_items_to_submit=>'P11_RUN_ID'
,p_series_type=>'bar'
,p_series_name_column_name=>'WAIT_CLASS'
,p_items_value_column_name=>'SECONDS_WAITED'
,p_group_name_column_name=>'WEEK_LABEL'
);
wwv_flow_imp_page.create_jet_chart_axis(
 p_id=>921100000000110029
,p_chart_id=>921100000000110027
,p_axis=>'x'
,p_is_rendered=>'on'
,p_title=>'Comparison Window'
);
wwv_flow_imp_page.create_jet_chart_axis(
 p_id=>921100000000110030
,p_chart_id=>921100000000110027
,p_axis=>'y'
,p_is_rendered=>'on'
,p_title=>'Seconds Waited'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>921100000000110031
,p_plug_name=>'Strongest Deviations'
,p_region_template_options=>'#DEFAULT#'
,p_component_template_options=>'#DEFAULT#'
,p_plug_template=>wwv_flow_imp.id(1041226926617276710)
,p_plug_display_sequence=>70
,p_ajax_items_to_submit=>'P11_RUN_ID'
,p_plug_source_type=>'NATIVE_JET_CHART'
);
wwv_flow_imp_page.create_jet_chart(
 p_id=>921100000000110032
,p_region_id=>921100000000110031
,p_chart_type=>'bar'
,p_title=>'Strongest Deviations'
,p_height=>'360'
,p_orientation=>'vertical'
,p_legend_rendered=>'off'
,p_tooltip_rendered=>'Y'
,p_show_value=>true
,p_no_data_found_message=>'No finding deviations available for this run.'
);
wwv_flow_imp_page.create_jet_chart_series(
 p_id=>921100000000110033
,p_chart_id=>921100000000110032
,p_seq=>10
,p_name=>'Absolute Z-Score'
,p_data_source_type=>'SQL'
,p_data_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select label, magnitude',
'from (',
'    select substr(metric_domain || '': '' || metric_name, 1, 40) as label,',
'           round(abs(nvl(z_score, 0)), 2) as magnitude,',
'           row_number() over (order by abs(nvl(z_score, 0)) desc, abs(nvl(pct_delta, 0)) desc, metric_name) as rn',
'    from awr_trend_findings',
'    where run_id = to_number(:P11_RUN_ID)',
')',
'where rn <= 10',
'order by magnitude desc, label'))
,p_ajax_items_to_submit=>'P11_RUN_ID'
,p_series_type=>'bar'
,p_items_value_column_name=>'MAGNITUDE'
,p_group_name_column_name=>'LABEL'
,p_items_label_rendered=>true
);
wwv_flow_imp_page.create_jet_chart_axis(
 p_id=>921100000000110034
,p_chart_id=>921100000000110032
,p_axis=>'x'
,p_is_rendered=>'on'
,p_title=>'Metric'
);
wwv_flow_imp_page.create_jet_chart_axis(
 p_id=>921100000000110035
,p_chart_id=>921100000000110032
,p_axis=>'y'
,p_is_rendered=>'on'
,p_title=>'Absolute Z-Score'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>921100000000110036
,p_plug_name=>'Run Snapshot'
,p_region_template_options=>'#DEFAULT#'
,p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders'
,p_plug_template=>wwv_flow_imp.id(1041226926617276710)
,p_plug_display_sequence=>80
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
'    skipped_windows',
'from awr_app_run_summary_v',
'where run_id = to_number(:P11_RUN_ID)'))
,p_plug_source_type=>'NATIVE_IR'
);
wwv_flow_imp_page.create_worksheet(
 p_id=>921100000000110037
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
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110038
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'RUN_ID'
,p_display_order=>10
,p_is_primary_key=>'Y'
,p_column_identifier=>'A'
,p_column_label=>'Run ID'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110039
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'TARGET_NAME'
,p_display_order=>20
,p_column_identifier=>'B'
,p_column_label=>'Target'
,p_column_type=>'STRING'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110040
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'DB_NAME'
,p_display_order=>30
,p_column_identifier=>'C'
,p_column_label=>'Database'
,p_column_type=>'STRING'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110041
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'STATUS'
,p_display_order=>40
,p_column_identifier=>'D'
,p_column_label=>'Status'
,p_column_type=>'STRING'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110042
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'TARGET_END_TS'
,p_display_order=>50
,p_column_identifier=>'E'
,p_column_label=>'Target End'
,p_column_type=>'DATE'
,p_tz_dependent=>'Y'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110043
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'WIN_HOURS'
,p_display_order=>60
,p_column_identifier=>'F'
,p_column_label=>'Window Hours'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110044
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'WEEKS_BACK'
,p_display_order=>70
,p_column_identifier=>'G'
,p_column_label=>'Weeks Back'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110045
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'TOP_N'
,p_display_order=>80
,p_column_identifier=>'H'
,p_column_label=>'Top N'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110046
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'CRITICAL_COUNT'
,p_display_order=>90
,p_column_identifier=>'I'
,p_column_label=>'Critical'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110047
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'WARN_COUNT'
,p_display_order=>100
,p_column_identifier=>'J'
,p_column_label=>'Warn'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110048
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'VALID_WINDOWS'
,p_display_order=>110
,p_column_identifier=>'K'
,p_column_label=>'Valid Windows'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>921100000000110049
,p_worksheet_id=>921100000000110037
,p_db_column_name=>'SKIPPED_WINDOWS'
,p_display_order=>120
,p_column_identifier=>'L'
,p_column_label=>'Skipped Windows'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_rpt(
 p_id=>921100000000110050
,p_application_user=>'APXWS_DEFAULT'
,p_report_seq=>10
,p_report_alias=>'RUN_VISUALS_SUMMARY'
,p_status=>'PUBLIC'
,p_is_default=>'Y'
,p_report_columns=>'RUN_ID:TARGET_NAME:DB_NAME:STATUS:TARGET_END_TS:WIN_HOURS:WEEKS_BACK:TOP_N:CRITICAL_COUNT:WARN_COUNT:VALID_WINDOWS:SKIPPED_WINDOWS'
);
wwv_flow_imp_page.create_page_process(
 p_id=>921100000000110051
,p_process_sequence=>10
,p_process_point=>'BEFORE_HEADER'
,p_process_type=>'NATIVE_PLSQL'
,p_process_name=>'Default Run'
,p_process_sql_clob=>wwv_flow_string.join(wwv_flow_t_varchar2(
'if :P11_RUN_ID is null then',
'    select max(run_id) into :P11_RUN_ID from awr_trend_runs;',
'end if;'))
,p_process_clob_language=>'PLSQL'
);
end;
/

begin
    wwv_flow_imp.import_end;
end;
/
