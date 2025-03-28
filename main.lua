-- DuckDB Plugin for Yazi
local M = {}

local set_mode = ya.sync(function(state, mode)
	state.mode = mode
end)

local get_mode = ya.sync(function(state)
	return state.mode or "summarized"
end)

-- Setup from init.lua: require("duckdb"):setup({ mode = "standard" })
function M:setup(opts)
	local default_mode = opts and opts.mode or "summarized"
	set_mode(default_mode)
end

-- Generates initial sql query on file.
local function generate_sql(job, mode)
	if mode == "standard" then
		return string.format("SELECT * FROM '%s' LIMIT 500", tostring(job.file.url))
	else
		return string.format(
			[[
			SELECT
				column_name AS column,
				column_type AS type,
				count,
				approx_unique AS unique,
				null_percentage AS null,
				LEFT(min, 10) AS min,
				LEFT(max, 10) AS max,
				CASE
					WHEN column_type IN ('TIMESTAMP', 'DATE') THEN '-'
					WHEN avg IS NULL THEN 'NULL'
					WHEN TRY_CAST(avg AS DOUBLE) IS NULL THEN avg
					WHEN CAST(avg AS DOUBLE) < 100000 THEN CAST(ROUND(CAST(avg AS DOUBLE), 2) AS VARCHAR)
					WHEN CAST(avg AS DOUBLE) < 1000000 THEN CAST(ROUND(CAST(avg AS DOUBLE) / 1000, 1) AS VARCHAR) || 'k'
					WHEN CAST(avg AS DOUBLE) < 1000000000 THEN CAST(ROUND(CAST(avg AS DOUBLE) / 1000000, 2) AS VARCHAR) || 'm'
					WHEN CAST(avg AS DOUBLE) < 1000000000000 THEN CAST(ROUND(CAST(avg AS DOUBLE) / 1000000000, 2) AS VARCHAR) || 'b'
					ELSE '∞'
				END AS avg,
				CASE
					WHEN column_type IN ('TIMESTAMP', 'DATE') THEN '-'
					WHEN std IS NULL THEN 'NULL'
					WHEN TRY_CAST(std AS DOUBLE) IS NULL THEN std
					WHEN CAST(std AS DOUBLE) < 100000 THEN CAST(ROUND(CAST(std AS DOUBLE), 2) AS VARCHAR)
					WHEN CAST(std AS DOUBLE) < 1000000 THEN CAST(ROUND(CAST(std AS DOUBLE) / 1000, 1) AS VARCHAR) || 'k'
					WHEN CAST(std AS DOUBLE) < 1000000000 THEN CAST(ROUND(CAST(std AS DOUBLE) / 1000000, 2) AS VARCHAR) || 'm'
					WHEN CAST(std AS DOUBLE) < 1000000000000 THEN CAST(ROUND(CAST(std AS DOUBLE) / 1000000000, 2) AS VARCHAR) || 'b'
					ELSE '∞'
				END AS std,
				CASE
					WHEN column_type IN ('TIMESTAMP', 'DATE') THEN '-'
					WHEN q25 IS NULL THEN 'NULL'
					WHEN TRY_CAST(q25 AS DOUBLE) IS NULL THEN q25
					WHEN CAST(q25 AS DOUBLE) < 100000 THEN CAST(ROUND(CAST(q25 AS DOUBLE), 2) AS VARCHAR)
					WHEN CAST(q25 AS DOUBLE) < 1000000 THEN CAST(ROUND(CAST(q25 AS DOUBLE) / 1000, 1) AS VARCHAR) || 'k'
					WHEN CAST(q25 AS DOUBLE) < 1000000000 THEN CAST(ROUND(CAST(q25 AS DOUBLE) / 1000000, 2) AS VARCHAR) || 'm'
					WHEN CAST(q25 AS DOUBLE) < 1000000000000 THEN CAST(ROUND(CAST(q25 AS DOUBLE) / 1000000000, 2) AS VARCHAR) || 'b'
					ELSE '∞'
				END AS q25,
				CASE
					WHEN column_type IN ('TIMESTAMP', 'DATE') THEN '-'
					WHEN q50 IS NULL THEN 'NULL'
					WHEN TRY_CAST(q50 AS DOUBLE) IS NULL THEN q50
					WHEN CAST(q50 AS DOUBLE) < 100000 THEN CAST(ROUND(CAST(q50 AS DOUBLE), 2) AS VARCHAR)
					WHEN CAST(q50 AS DOUBLE) < 1000000 THEN CAST(ROUND(CAST(q50 AS DOUBLE) / 1000, 1) AS VARCHAR) || 'k'
					WHEN CAST(q50 AS DOUBLE) < 1000000000 THEN CAST(ROUND(CAST(q50 AS DOUBLE) / 1000000, 2) AS VARCHAR) || 'm'
					WHEN CAST(q50 AS DOUBLE) < 1000000000000 THEN CAST(ROUND(CAST(q50 AS DOUBLE) / 1000000000, 2) AS VARCHAR) || 'b'
					ELSE '∞'
				END AS q50,
				CASE
					WHEN column_type IN ('TIMESTAMP', 'DATE') THEN '-'
					WHEN q75 IS NULL THEN 'NULL'
					WHEN TRY_CAST(q75 AS DOUBLE) IS NULL THEN q75
					WHEN CAST(q75 AS DOUBLE) < 100000 THEN CAST(ROUND(CAST(q75 AS DOUBLE), 2) AS VARCHAR)
					WHEN CAST(q75 AS DOUBLE) < 1000000 THEN CAST(ROUND(CAST(q75 AS DOUBLE) / 1000, 1) AS VARCHAR) || 'k'
					WHEN CAST(q75 AS DOUBLE) < 1000000000 THEN CAST(ROUND(CAST(q75 AS DOUBLE) / 1000000, 2) AS VARCHAR) || 'm'
					WHEN CAST(q75 AS DOUBLE) < 1000000000000 THEN CAST(ROUND(CAST(q75 AS DOUBLE) / 1000000000, 2) AS VARCHAR) || 'b'
					ELSE '∞'
				END AS q75
			FROM (summarize FROM '%s')]],
			tostring(job.file.url)
		)
	end
end

-- Get preview cache path
local function get_cache_path(job, mode)
	local skip = job.skip
	job.skip = 0
	local base = ya.file_cache(job)
	job.skip = skip
	if not base then
		return nil
	end
	return Url(tostring(base) .. "_" .. mode .. ".db")
end

-- Run queries.
local function run_query(job, query, target)
	local args = {}
	if target ~= job.file.url then
		table.insert(args, tostring(target))
	end
	table.insert(args, "-c")
	table.insert(args, query)
	local child = Command("duckdb"):args(args):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if not child then
		return nil
	end
	local output, err = child:wait_with_output()
	if err or not output.status.success then
		return nil
	end
	return output
end

-- Create Caches.
local function create_cache(job, mode, path)
	if fs.cha(path) then
		return true
	end
	local sql = generate_sql(job, mode)
	local out = run_query(job, string.format("CREATE TABLE My_table AS (%s);", sql), path)
	return out ~= nil
end

-- Generate queries on files respecting view space.
local function generate_query(target, job, limit, offset)
	local mode = get_mode()
	if target == job.file.url then
		if mode == "standard" then
			return string.format("SELECT * FROM '%s' LIMIT %d OFFSET %d;", tostring(target), limit, offset)
		else
			local query = generate_sql(job, mode)
			return string.format("WITH query AS (%s) SELECT * FROM query LIMIT %d OFFSET %d;", query, limit, offset)
		end
	else
		return string.format("SELECT * FROM My_table LIMIT %d OFFSET %d;", limit, offset)
	end
end

-- Preload summarized and standard preview caches
function M:preload(job)
	for _, mode in ipairs({ "standard", "summarized" }) do
		local path = get_cache_path(job, mode)
		if path and not fs.cha(path) then
			create_cache(job, mode, path)
		end
	end
	return true
end

-- Peek.
function M:peek(job)
	local raw_skip = job.skip or 0
	local skip = math.max(0, raw_skip - 50)
	job.skip = skip

	local mode = get_mode()

	local cache = get_cache_path(job, mode)
	local file_url = job.file.url
	local target = (cache and fs.cha(cache)) and cache or file_url

	local limit = job.area.h - 7
	local offset = skip
	local query = generate_query(target, job, limit, offset)

	local output = run_query(job, query, target)

	if not output or output.stdout == "" then
		if target ~= file_url then
			target = file_url
			query = generate_query(target, job, limit, offset)
			output = run_query(job, query, target)

			if not output or output.stdout == "" then
				return require("code"):peek(job)
			end
		else
			return require("code"):peek(job)
		end
	end

	ya.preview_widgets(job, { ui.Text.parse(output.stdout):area(job.area) })
end

-- Seek
function M:seek(job)
	local OFFSET_BASE = 50
	local current_skip = math.max(0, cx.active.preview.skip - OFFSET_BASE)
	local units = job.units or 0
	local new_skip = current_skip + units

	if new_skip < 0 then
		-- Toggle preview mode
		local mode = get_mode()
		local new_mode = (mode == "summarized") and "standard" or "summarized"
		set_mode(new_mode)

		-- Trigger re-peek
		ya.manager_emit("peek", { OFFSET_BASE, only_if = job.file.url })
	else
		ya.manager_emit("peek", { new_skip + OFFSET_BASE, only_if = job.file.url })
	end
end

return M
