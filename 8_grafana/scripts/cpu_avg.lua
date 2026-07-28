
function compute_cpu_avg(tag, ts, record)
	local cpu_sum = 0
	local user_sum = 0
	local sys_sum = 0
	local count = 0

	for k, v in pairs(record) do
		if string.match(k, "^cpu%d+%.p_cpu$") then
			cpu_sum = cpu_sum + v
			count = count + 1
		elseif string.match(k, "^cpu%d+%.p_user$") then
			user_sum = user_sum + v
		elseif string.match(k, "^cpu%d+%.p_system$") then
			sys_sum = sys_sum + v
		end
	end

	if count > 0 then
		record["cpu_p"] = cpu_sum / count
		record["user_p"] = user_sum / count
		record["system_p"] = sys_sum / count
	end

	for k, _ in pairs(record) do
		if string.match(k, "^cpu%d+%.p_") then
			record[k] = nil
		end
	end

	return 1, ts, record
end
