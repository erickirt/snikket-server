local usermanager = require "prosody.core.usermanager";

local http = require "prosody.net.http";
local json = require "prosody.util.json";
local promise = require "prosody.util.promise";

local health_report_api = module:get_option_string("health_report_api");
local auth_token = module:get_option_string("health_report_api_key");
local report_frequency = module:get_option_string("health_report_frequency", "hourly");

if not health_report_api or not auth_token then
	module:set_status("info", "Inactive - not configured");
	return;
end

local metric_registry = require "core.statsmanager".get_metric_registry();

local mod_audit_status = module:depends("audit_status");
local mod_measure_active_users = module:depends("measure_active_users");
local mod_snikket_version = module:depends("snikket_version");
local mod_invites = module:depends("invites");

local last_health_report;

local function has_changed(new, old)
	if old == nil then return true; end
	for k, v in pairs(new) do
		if v ~= old[k] then
			return true;
		end
	end
	return false;
end

local function get_gauge_metric(name)
	return (metric_registry.families[name].data:get(module.host) or {}).value;
end

local function get_bootstrap_status()
	local admins = usermanager.get_users_with_role("prosody:admin", module.host);
	if admins and #admins > 0 then
		return "ok";
	end

	-- No admin account yet
	for _, invite in mod_invites.pending_account_invites() do
		local invite_roles = invite.additional_data and invite.additional_data.roles;
		if invite_roles then
			for _, role_name in ipairs(invite_roles) do
				if role_name == "prosody:admin" then
					-- Found a pending admin invite
					return "pending";
				end
			end
		end
	end

	-- No pending admin invite yet
	if module:get_option_string("invites_bootstrap_secret") then
		return "ready";
	end

	-- No admin, no pending invite, not in bootstrap mode... oh no
	return "unavailable";
end

function report_health()
	local url = health_report_api:gsub("DOMAIN", http.urlencode(module.host));

	mod_measure_active_users.update_calculations();

	local health = {
		launch_time = prosody.start_time;
		crashed = not not mod_audit_status.crashed;
		bootstrap_status = get_bootstrap_status();
		dau = get_gauge_metric("prosody_mod_measure_active_users/active_users_1d");
		wau = get_gauge_metric("prosody_mod_measure_active_users/active_users_7d");
		mau = get_gauge_metric("prosody_mod_measure_active_users/active_users_30d");
		version = mod_snikket_version.snikket_version;
	};

	if not has_changed(health, last_health_report) then
		return;
	end

	http.request(url, {
		headers = {
			["Content-Type"] = "application/json";
			["Authorization"] = "Bearer "..auth_token;
		};
		body = json.encode(health);
	}):next(function (response)
		if response.code ~= 200 or response.headers["content-type"] ~= "application/json" then
			module:log("warn", "Health API error %d (%s)", response.code, response.headers["content-type"]);
			if response.headers["content-type"] == "application/json" then
				module:log("warn", "Error: %s", response.body);
			end
			return promise.reject("API error");
		end
		last_health_report = health;
		module:log("info", "Submitted health report");
	end)
	:catch(function (e)
		module:log("warn", "Failed to send health report: %s", e);
	end);


end

function module.ready()
	local secs = math.random(60, 90);
	module:log("debug", "Scheduled initial health report in %ds", secs);
	module:add_timer(secs, function ()
		report_health();
		module:cron({
			when = report_frequency;
			run = report_health;
		});
	end);
end

local pending_report = false;

function schedule_report_update()
	if pending_report then return; end
	module:add_timer(math.random(30, 60), function ()
		pending_report = false;
		report_health();
	end);
end

module:hook("client_management/new-client", schedule_report_update);
