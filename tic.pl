#!/usr/bin/perl
#############################
# 	Tic v0.13.0         #
# Created by Josh McDougall #
#############################
# This no longer sits in the cron and should be run in a screen session instead


# use module
use DBI; 
 
#My quick off switch
while (1){ 

# Config Variables
my $db_name 	= "schemaverse";
my $db_username = "schemaverse";

# Make the master database connection
my $master_connection = DBI->connect("dbi:Pg:dbname=${db_name};host=localhost", $db_username);

$master_connection->do('SELECT ROUND_CONTROL();');

# Move the rest of the ships in whatever direction they have specified
my $sql = <<SQLSTATEMENT;
BEGIN WORK;
LOCK TABLE ship, ship_control IN EXCLUSIVE MODE;
	SELECT MOVE_SHIPS();
COMMIT WORK;
SQLSTATEMENT
$master_connection->do($sql); 

my $sql = <<SQLSTATEMENT;
    SELECT update_ships_near_ships();
    SELECT update_ships_near_planets();    
SQLSTATEMENT
$master_connection->do($sql); 

# Retreive Fleet Scripts and run them as the user they belong to
my $sql = <<SQLSTATEMENT;
SELECT 
	player.id as player_id,
	player.username as username,
	fleet.id as fleet_id,
	player.error_channel as error_channel
FROM 
	fleet, player
WHERE
	fleet.player_id=player.id
	AND
	fleet.enabled='t'
	AND 
	fleet.runtime > '0 minutes'::interval
ORDER BY 
	player.username;
SQLSTATEMENT

my $rs = $master_connection->prepare($sql); 
$rs->execute();
$temp_user = '';
while (($player_id, $player_username, $fleet_id, $error_channel) = $rs->fetchrow()) {

	if ($temp_user ne $player_username)
	{
		if ($temp_user ne '')
		{
			$temp_connection->disconnect();
			
		}
		$temp_user = $player_username;
		$temp_connection = DBI->connect("dbi:Pg:dbname=$db_name;host=localhost", $player_username);
		$temp_connection->{PrintError} = 0;
		$temp_connection->{RaiseError} = 1;
	}
	#$temp_connection->{application_name} = $fleet_id;
	$temp_connection->do("SET application_name TO ${fleet_id}");
	eval { $temp_connection->do("SELECT RUN_FLEET_SCRIPT(${fleet_id})"); };
  	if( $@ ) {
		$temp_connection->do("NOTIFY ${error_channel}, 'Fleet script ${fleet_id} has failed to fully execute during the tic'; ");
	}
}
if ($temp_user ne '') {
	$temp_connection->disconnect();
}
$rs->finish;

# Perform actions for all ships where target is not null
my $sql = <<SQLSTATEMENT;
BEGIN WORK;
LOCK TABLE ship, ship_control IN EXCLUSIVE MODE;
SELECT 
	CASE 
		WHEN ship_control.action = 'ATTACK' THEN ATTACK(ship.id, ship_control.action_target_id)::integer
		WHEN ship_control.action = 'REPAIR' THEN REPAIR(ship.id, ship_control.action_target_id)::integer
		WHEN ship_control.action = 'MINE' THEN MINE(ship.id, ship_control.action_target_id)::integer
		ELSE NULL END
FROM 
	ship, ship_control  
WHERE
	 ship.id = ship_control.ship_id
	AND
	ship_control.action IS NOT NULL
        AND
	ship_control.action_target_id IS NOT NULL
	AND
	ship.destroyed='f'
	AND 
	ship.last_action_tic != (SELECT last_value FROM tic_seq);
COMMIT WORK;
SQLSTATEMENT
$master_connection->do($sql); 



#planets are mined
$master_connection->do("SELECT perform_mining()");

#dirty planet renewal hack
$master_connection->do("UPDATE planet SET fuel=fuel+1000000 WHERE id in (select id from planet where fuel < 10000000 order by RANDOM() LIMIT 5000);");
	
#future_health is dealt with
$master_connection->do("BEGIN WORK; 
LOCK TABLE ship, ship_control IN EXCLUSIVE MODE; 
create temp table t_ship_updates (id integer, current_health integer, future_health integer, max_health integer, last_living_tic integer, destroyed boolean, player_id integer);
insert into t_ship_updates (id, current_health, future_health, max_health, last_living_tic, destroyed, player_id)
  select id, current_health, future_health, max_health, last_living_tic, destroyed, player_id
  from ship;
UPDATE t_ship_updates SET current_health=max_health WHERE future_health >= max_health and current_health <> max_health; 
UPDATE t_ship_updates SET current_health=future_health WHERE future_health between 0 and max_health and current_health <> max_health;
UPDATE t_ship_updates SET current_health=0 WHERE future_health < 0 and current_health <> 0;
UPDATE t_ship_updates SET last_living_tic=(SELECT last_value FROM tic_seq) WHERE current_health > 0;
UPDATE t_ship_updates SET destroyed='t' WHERE ((SELECT last_value FROM tic_seq)-last_living_tic)>GET_NUMERIC_VARIABLE('EXPLODED') and player_id > 0;
create index t_id on t_ship_updates (id);
update ship s
  set current_health = (select current_health from t_ship_updates where id = s.id),
      last_living_tic = (select last_living_tic from t_ship_updates where id = s.id),
      destroyed = (select destroyed from t_ship_updates where id = s.id);
COMMIT WORK;");

$master_connection->do("vacuum ship;");

#Update some stats now and then
$master_connection->do("insert into stat_log  select * from current_stats WHERE mod(current_tic,60)=0;");


$master_connection->do("INSERT INTO event(player_id_1, action, tic, public) VALUES(0,'TIC',(SELECT last_value FROM tic_seq)",'t');

#Tic is increased to NEXTVAL
$master_connection->do("SELECT nextval('tic_seq')");	

$master_connection->disconnect();
sleep(60);

}
