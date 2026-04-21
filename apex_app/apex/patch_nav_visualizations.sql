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
end;
/

begin
wwv_flow_imp_shared.create_list_item(
 p_id=>907848594392273062
,p_list_id=>1048671581951822723
,p_list_item_display_sequence=>35
,p_list_item_link_text=>'Visualizations'
,p_list_item_link_target=>'f?p=&APP_ID.:11:&APP_SESSION.::&DEBUG.:'
,p_list_item_icon=>'fa-area-chart'
,p_list_item_current_type=>'TARGET_PAGE'
);
end;
/

begin
    wwv_flow_imp.import_end;
end;
/
