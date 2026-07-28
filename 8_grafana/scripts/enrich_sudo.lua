
function enrich_sudo(tag, timestamp, record)
    -- Only enrich sudo lines
    if record["program"] == "sudo" and record["message"] then
		local tty, pwd, user, cmd = string.match(record["message"], "TTY=(%S+) ; PWD=(%S+) ; USER=(%S+) ; COMMAND=(.+)")
		if user and cmd then
			-- Track which parsers ran
			record["parsers"] = record["parsers"] or {}
			table.insert(record["parsers"], "auth_basic")

			-- extract user root
			local sudo_user, target_user = string.match(record["message"], "session opened for user (%S+) %(uid=%d+%) by %(uid=(%d+)%)")
			if sudo_user then record["target_user"] = sudo_user end
			if target_user then record["sudo_user_id"] = tonumber(target_user) end

			-- extract command info
			record["tty"] = tty
			record["pwd"] = pwd
			record["sudo_user"] = user
			record["command"] = cmd
        end
    end

    return 1, timestamp, record
end
