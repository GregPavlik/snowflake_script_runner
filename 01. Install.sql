/********************************************************************************************************
*                                                                                                       *
*                                       Snowflake Script Runner                                         *
*                                                                                                       *
*  Copyright (c) 2020 Snowflake Computing Inc. All rights reserved.                                     *
*                                                                                                       *
*  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in  *
*. compliance with the License. You may obtain a copy of the License at                                 *
*                                                                                                       *
*                               http://www.apache.org/licenses/LICENSE-2.0                              *
*                                                                                                       *
*  Unless required by applicable law or agreed to in writing, software distributed under the License    *
*  is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or  *
*  implied. See the License for the specific language governing permissions and limitations under the   *
*  License.                                                                                             *
*                                                                                                       *
*  Copyright (c) 2020 Snowflake Computing Inc. All rights reserved.                                     *
*                                                                                                       *
********************************************************************************************************/

/****************************************************************************************************
*                                                                                                   *
*                               ***  Snowflake Script Runner   ***                                  *
*                                                                                                   *
*  Provide feedback to greg at pavlik.us                                                            *
*                                                                                                   *
*  ==> Purpose: This project will run a set of SQL commands scripted into a table. Refer to the     *
*               section detailing the table structure to write scripts for this procedure to run.   *
*  ==> Setup:   1) Create all objects in this worksheet in a database of your choice.               *
*               2) Create a script table holding all your SQL commands.                             *
*               3) Insert rows with the same "SCRIPT_NAME" value, sorted in the "RUN_ORDER".        *
*                                                                                                   *
*  ==> Running: 1) If you will be creating a DB oe schema, it is highly advisable to use fully      *
*                  qualified object names (DATABASE.SCHEMA.TABLE) because creating these objects    *
*                  will change your session context. It may take a while for the UI to refresh,     *
*                  and this can be confusing. Three part qualifiers avoid this ambiguity.           *
*               2) Set variables using the syntax @variable_name=<expression>                       *
*               3) Variables are case sensitive, and the <expression> is an expression that         *
*                  returns a signle row like this -- select <expression> as VARIABLE;               *
*                                                                                                   *
****************************************************************************************************/


-- You will need a database named TEST for this script. If you alredy have a TEST database and don't want 
-- to use it, you can change all references to the TEST database in this script.
create database if not exists TEST;
create schema if not exists SCRIPT_TEST;

-- Create your script table. This contains one or more SQL scripts to run.
create or replace table TEST.SCRIPT_TEST.SCRIPT_TABLE
(
    SCRIPT_NAME         string,                                 -- The script name to run. You can have as many scripts names as you want as long as they have unique names.
    RUN_ORDER           integer,                                -- The order you want to run the SQL statements. This can be any data type and value that works in ORDER BY
    SQL_COMMAND         string,                                 -- The SQL command to run. You can also set script variables here. See usage notes in the RUN_SCRIPT procedure.
    CONTINUE_ON_ERROR   boolean     default false               -- Set to false to terminate if a line encounters an error. Set to true to continue on error for that statement only.
);

-- Add some rows to our sample script. Name this one CLONE_TEST_DB. You can add as many scripts in the table as you want.
insert into TEST.SCRIPT_TEST.SCRIPT_TABLE
(
    SCRIPT_NAME, RUN_ORDER, SQL_COMMAND, CONTINUE_ON_ERROR
)
values
    ('CLONE_TEST_DB', 10, '@DB_NAME=''TEST_CLONE_'' || replace(current_date(), ''-'', ''_'')', false),
    ('CLONE_TEST_DB', 30, 'drop database if exists @DB_NAME;', true),
    ('CLONE_TEST_DB', 40, 'create database @DB_NAME clone TEST', false),
    ('CLONE_TEST_DB', 50, 'revoke all PRIVILEGES on database @DB_NAME from role PUBLIC;', false),
    ('CLONE_TEST_DB', 60, 'grant all privileges on database @DB_NAME to role SYSADMIN;', false),
    ('CLONE_TEST_DB', 70, 'use database TEST;', true)
;

-- Take note of the first statement in the script. Due to limitations with Snowflake stored procedures session variables and limitations for identifiers,
-- this project uses replacement variables. They replace exactly as they're specified using the syntax in the script table:  @VARIABLE_NAME=VARIABLE_VALUE

-- +++> IMPORTANT <=== The stored procedure *EVALUATES* the variable like this:    select <expression> as VARIABLE
-- It will evaluate this expresion and use it for the variable. 
-- For example the first line in the script above is @DB_NAME='TEST_CLONE_ || replace(current_date(), '-', '_');
-- This evaluates like this:

    select 'TEST_CLONE_' || replace(current_date(), '-', '_') as VARIABLE;
--  ^^^^^^                                                    ^^^^^^^^^^^^
--  The stored procedure adds the parts marked ^^^^ to show how it will evaluate the replacement variables. This allows you to use any Snowflake supported syntax
--  to create the replacement variables. If you want just a simple string, use @MY_VARIABLE='MY_VALUE'

-- Examine your script to make sure it's the way you want it.
select * from TEST.SCRIPT_TEST.SCRIPT_TABLE where SCRIPT_NAME = 'CLONE_TEST_DB' order by RUN_ORDER;

-- Create the stored procedure
create or replace procedure TEST.SCRIPT_TEST.RUN_SCRIPT(SCRIPT_TABLE string, SCRIPT_NAME string)
    returns string
    language JavaScript
    execute as caller
as
$$

/****************************************************************************************************
*                                                                                                   *
* Stored procedure to run a script stored as multiple, ordered rows in a table                      *
*                                                                                                   *
* @param  {string}  SCRIPT_TABLE:       The name of the script table. See usage notes               *
* @param  {string}  SCRIPT_NAME:        The name of the script in the script table                  *
* @return {string}:                     A multi-line string with query IDs and status               *
*                                                                                                   *
****************************************************************************************************/

    cmd1 = {sqlText: `select SQL_COMMAND, CONTINUE_ON_ERROR from ${SCRIPT_TABLE} where SCRIPT_NAME = '${SCRIPT_NAME}' order by RUN_ORDER`};
    stmt = snowflake.createStatement(cmd1);
    try{
        rs = stmt.execute();
    }
    catch(err){
        return err;
    } 
    var replacements = [];
    var s = '';
    var r = '';
    var sql = '';
    var pass = 0;
    var keyValuePair = [];
    while (rs.next()) {
        sql = rs.getColumnValue("SQL_COMMAND");
        if(pass++ > 0) s += '\n';
        if (sql.substring(0, 1) == "@"){
            keyValuePair = sql.split(/=(.+)/);
            try{
                keyValuePair[1] = ExecuteSingleValueQuery("VARIABLE", "select " + keyValuePair[1] + " as VARIABLE;");
            }
            catch(err){
                if (rs.getColumnValue("CONTINUE_ON_ERROR") == false){
                    s += GetLastQueryID() + ":ERROR: Failed to set variable. Refer to usage notes for setting variables using @VARNAME=<expression> syntax.";
                    break;
                }
            }
            replacements.push(keyValuePair);
            s += keyValuePair[0] + "=" + keyValuePair[1];
        }
        else{
            r = ExecuteSQL(ReplaceVariables(sql, replacements));
            s += r;
            if(r.split(":")[1] == "ERROR" && rs.getColumnValue("CONTINUE_ON_ERROR") == false){
                break;
            }
        }
    }
    return s;

// ----- End of main function -----

function ReplaceVariables(sql, replacements){
    for (var i=0; i < replacements.length; i++){
      sql = sql.replace(new RegExp(replacements[i][0]), replacements[i][1]);
    }
    return sql;
}

// -------- SQL functions ---------


    function ExecuteSQL(queryString) {
        var out;
        cmd1 = {sqlText: queryString};
        stmt = snowflake.createStatement(cmd1);
        var rs;
        try{
            rs = stmt.execute();
            return stmt.getQueryId() + ":" + "SUCCESS";
        }
        catch(err){
            return GetLastQueryID() + ":" + "ERROR:" + err.message;
        }
    }
    
    function GetLastQueryID(){
        return ExecuteSingleValueQuery("ID", "select last_query_id() as ID;");
    }
    
    function ExecuteSingleValueQuery(columnName, queryString) {
        var out;
        cmd1 = {sqlText: queryString};
        stmt = snowflake.createStatement(cmd1);
        var rs;
        rs = stmt.execute();
        rs.next();
        return rs.getColumnValue(columnName);
        return out;
    }    
$$
;

-- Run the stored procedure. It will clone the TEST database with a new name including today's date.
-- It will set the permissions. Naturally, you'll want to add a lot more steps to your script to 
-- set permissions the way you want them, etc.
call test.script_test.run_script('TEST.SCRIPT_TEST.SCRIPT_TABLE', 'CLONE_TEST_DB');


-- NOTE: You can click on the output of the stored procedure to see the execution status of each SQL statement in the script

-- Snowflake Stored Procedures run serially in the same session, so you should not need to wait between SQL commands.
-- If for some reason your script requires a wait on an external dependency, you can call this stored procedure
-- From your script. It will wait the number of seconds you tell it to wait before resuming the script. Note that this
-- should only be used for short waits because it will keep the warehouse active while it's waiting.
create or replace procedure TEST.SCRIPT_TEST.WAIT(SECONDS float)
    returns string
    language javascript
as
$$

    return wait(SECONDS);

function wait(seconds) { 
    var now = new Date(); 
    var waitTime = now.getTime() + seconds * 1000; 
    while (true) { 
        now = new Date(); 
        if (now.getTime() > waitTime) 
            return `Waited ${seconds} seconds.`; 
    } 
}

$$;

call test.script_test.wait(5);
