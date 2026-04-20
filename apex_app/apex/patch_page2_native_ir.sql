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
    wwv_flow_imp_page.remove_page(p_flow_id => 100, p_page_id => 2);
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>2
,p_user_interface_id=>1045062637249549896
,p_name=>'Runs'
,p_alias=>'RUNS'
,p_step_title=>'Runs'
,p_autocomplete_on_off=>'OFF'
,p_page_template_options=>'#DEFAULT#'
,p_last_updated_by=>'AWR_APEX'
,p_last_upd_yyyymmddhh24miss=>'20260420210000'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>920200000000020001
,p_plug_name=>'Runs'
,p_icon_css_classes=>'fa-history'
,p_region_template_options=>'#DEFAULT#'
,p_escape_on_http_output=>'Y'
,p_plug_template=>1044967870434549751
,p_plug_display_sequence=>10
,p_plug_display_point=>'REGION_POSITION_01'
,p_attribute_01=>'N'
,p_attribute_02=>'HTML'
,p_attribute_03=>'Y'
);
wwv_flow_imp_page.create_page_plug(
 p_id=>920200000000020002
,p_plug_name=>'Recent Runs'
,p_region_template_options=>'#DEFAULT#'
,p_component_template_options=>'#DEFAULT#:t-IRR-region--noBorders'
,p_plug_template=>1044975521009549762
,p_plug_display_sequence=>20
,p_plug_display_point=>'BODY'
,p_query_type=>'SQL'
,p_plug_source=>wwv_flow_string.join(wwv_flow_t_varchar2(
'select',
'    run_id,',
'    target_name,',
'    status,',
'    target_end_ts,',
'    generated_at,',
'    critical_count,',
'    warn_count',
'from awr_app_run_summary_v',
'order by generated_at desc, run_id desc'))
,p_plug_source_type=>'NATIVE_IR'
);
wwv_flow_imp_page.create_worksheet(
 p_id=>920200000000020003
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
 p_id=>920200000000020004
,p_worksheet_id=>920200000000020003
,p_db_column_name=>'RUN_ID'
,p_display_order=>10
,p_is_primary_key=>'Y'
,p_column_identifier=>'A'
,p_column_label=>'Run ID'
,p_column_link=>'f?p=&APP_ID.:3:&SESSION.::&DEBUG.::P3_RUN_ID:#RUN_ID#'
,p_column_linktext=>'#RUN_ID#'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>920200000000020005
,p_worksheet_id=>920200000000020003
,p_db_column_name=>'TARGET_NAME'
,p_display_order=>20
,p_column_identifier=>'B'
,p_column_label=>'Target'
,p_column_type=>'STRING'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>920200000000020006
,p_worksheet_id=>920200000000020003
,p_db_column_name=>'STATUS'
,p_display_order=>30
,p_column_identifier=>'C'
,p_column_label=>'Status'
,p_column_type=>'STRING'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>920200000000020007
,p_worksheet_id=>920200000000020003
,p_db_column_name=>'TARGET_END_TS'
,p_display_order=>40
,p_column_identifier=>'D'
,p_column_label=>'Target End'
,p_column_type=>'DATE'
,p_heading_alignment=>'LEFT'
,p_tz_dependent=>'Y'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>920200000000020008
,p_worksheet_id=>920200000000020003
,p_db_column_name=>'GENERATED_AT'
,p_display_order=>50
,p_column_identifier=>'E'
,p_column_label=>'Generated'
,p_column_type=>'DATE'
,p_heading_alignment=>'LEFT'
,p_tz_dependent=>'Y'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>920200000000020009
,p_worksheet_id=>920200000000020003
,p_db_column_name=>'CRITICAL_COUNT'
,p_display_order=>60
,p_column_identifier=>'F'
,p_column_label=>'Critical'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_column(
 p_id=>920200000000020010
,p_worksheet_id=>920200000000020003
,p_db_column_name=>'WARN_COUNT'
,p_display_order=>70
,p_column_identifier=>'G'
,p_column_label=>'Warn'
,p_column_type=>'NUMBER'
,p_heading_alignment=>'RIGHT'
,p_column_alignment=>'RIGHT'
);
wwv_flow_imp_page.create_worksheet_rpt(
 p_id=>920200000000020011
,p_application_user=>'APXWS_DEFAULT'
,p_report_seq=>10
,p_report_alias=>'RUNS_DEFAULT'
,p_status=>'PUBLIC'
,p_is_default=>'Y'
,p_report_columns=>'RUN_ID:TARGET_NAME:STATUS:TARGET_END_TS:GENERATED_AT:CRITICAL_COUNT:WARN_COUNT'
);
end;
/

begin
    wwv_flow_imp.import_end;
end;
/
