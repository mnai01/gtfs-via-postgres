#!/bin/bash

set -e
set -o pipefail
cd "$(dirname $0)"
set -x

env | grep '^PG' || true

unzip -q -j -n amtrak-gtfs-2021-10-06.zip -d amtrak-gtfs-2021-10-06
ls -lh amtrak-gtfs-2021-10-06

psql -c 'create database amtrak_2021_10_06'
export PGDATABASE='amtrak_2021_10_06'

../cli.js -d --trips-without-shape-id --schema amtrak \
	--import-metadata \
	--stats-by-route-date=view \
	--stats-by-agency-route-stop-hour=view \
	--stats-active-trips-by-hour=view \
	--postgrest \
	-- amtrak-gtfs-2021-10-06/*.txt \
	| sponge | psql -b

query=$(cat << EOF
select extract(epoch from t_arrival)::integer as t_arrival
from amtrak.arrivals_departures
where stop_id = 'BHM' -- Birmingham
and date = '2021-11-26'
order by t_arrival
EOF)

# 2021-11-26T15:15:00-05:00
arr1=$(psql --csv -t -c "$query" | head -n 1)
if [[ "$arr1" != "1637957700" ]]; then
	echo "invalid 1st t_arrival: $arr1" 1>&2
	exit 1
fi

# 2021-11-27T13:45:00-05:00
arrN=$(psql --csv -t -c "$query" | tail -n 1)
if [[ "$arrN" != "1638038700" ]]; then
	echo "invalid 2nd t_arrival: $arrN" 1>&2
	exit 1
fi

version=$(psql --csv -t -c "SELECT split_part(amtrak.gtfs_via_postgres_version(), '.', 1)" | tail -n 1)
if [[ "$version" != "4" ]]; then
	echo "invalid gtfs_via_postgres_version(): $version" 1>&2
	exit 1
fi

fMin=$(psql --csv -t -c "SELECT amtrak.dates_filter_min('2021-11-27T13:45:00-06')" | tail -n 1)
if [[ "$fMin" != "2021-11-24" ]]; then
	echo "invalid dates_filter_min(…): $fMin" 1>&2
	exit 1
fi

acelaStatQuery=$(cat << EOF
SELECT nr_of_trips, nr_of_arrs_deps
FROM amtrak.stats_by_route_date
WHERE route_id = '40751' -- Acela
AND date = '2021-11-26'
AND is_effective = True
EOF)
acelaStat=$(psql --csv -t -c "$acelaStatQuery" | tail -n 1)
if [[ "$acelaStat" != "16,190" ]]; then
	echo "invalid stats for route 40751 (Acela) on 2021-11-26: $acelaStat" 1>&2
	exit 1
fi

acelaPhillyStatQuery=$(cat << EOF
SELECT nr_of_arrs
FROM amtrak.stats_by_agency_route_stop_hour
WHERE route_id = '40751' -- Acela
AND stop_id = 'PHL' -- Philadelphia
AND effective_hour = '2022-07-24T09:00-05'
EOF)
acelaPhillyStat=$(psql --csv -t -c "$acelaPhillyStatQuery" | tail -n 1)
if [[ "$acelaPhillyStat" != "2" ]]; then
	echo "invalid stats for route 40751 (Acela) at PHL (Philadelphia) on 2021-11-26: $acelaPhillyStat" 1>&2
	exit 1
fi

nrOfActiveTripsQuery=$(cat << EOF
SELECT nr_of_active_trips
FROM amtrak.stats_active_trips_by_hour
WHERE "hour" = '2021-11-26T04:00-05'
EOF)
# Note: I'm not sure if 127 is correct, but it is in the right ballpark. 🙈
# The following query yields 150 connections, and it doesn't contain those who depart earlier and arrive later.
# SELECT DISTINCT ON (trip_id) *
# FROM amtrak.connections
# WHERE t_departure >= '2021-11-26T02:00-05'
# AND t_arrival <= '2021-11-26T06:00-05'
nrOfActiveTrips=$(psql --csv -t -c "$nrOfActiveTripsQuery" | tail -n 1)
if [[ "$nrOfActiveTrips" != "127" ]]; then
	echo "unexpected no. of active trips at 2021-11-26T04:00-05: $nrOfActiveTrips" 1>&2
	exit 1
fi

# kill child processes on exit
# https://stackoverflow.com/questions/360201/how-do-i-kill-background-processes-jobs-when-my-shell-script-exits/2173421#2173421
trap 'exit_code=$?; kill -- $(jobs -p); exit $exit_code' SIGINT SIGTERM EXIT

env \
	PGRST_DB_SCHEMAS=amtrak \
	PGRST_DB_ANON_ROLE=web_anon \
	PGRST_ADMIN_SERVER_PORT=3001 \
	PGRST_LOG_LEVEL=info \
	postgrest &
	# docker run --rm -i \
	# -p 3000:3000 -p 3001:3001 \
	# -e PGHOST=host.docker.internal -e PGUSER -e PGPASSWORD -e PGDATABASE \
	# postgrest/postgrest &
sleep 3

health_status="$(curl 'http://localhost:3001/live' -I -fsS | grep -o -m1 -E '[0-9]{3}')"
if [ "$health_status" != '200' ]; then
	1>&2 echo "/live: expected 200, got $health_status"
	exit 1
fi

stops_url='http://localhost:3000/stops?stop_name=ilike.%25palm%25&limit=1&order=stop_id.asc'
stops_status="$(curl "$stops_url" -H 'Accept: application/json' -I -fsS | grep -o -m1 -E '[0-9]{3}')"
if [ "$stops_status" != '200' ]; then
	1>&2 echo "$stops_url: expected 200, got $stops_status"
	exit 1
fi
stop_id="$(curl "$stops_url" -H 'Accept: application/json' -fsS | jq -rc '.[0].stop_id')"
if [ "$stop_id" != 'PDC' ]; then
	1>&2 echo "$stops_url: expected PDC, got $stop_id"
	exit 1
fi
