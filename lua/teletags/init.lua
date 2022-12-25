--[[ this module exposes the interface of lua functions:
define here the lua functions that activate the plugin ]]

-- local main = require("teletags.main")
-- local config = require("teletags.config")

------------------
local log = require('plenary.log').new({
    plugin = 'teletags',
    level = "debug",
    use_console = false,
})

local find_tags = function(tag)
    local found_tags = vim.fn.taglist('^\\C' .. tag .. '$')
    if found_tags then
        return found_tags
    else
        return {}
    end
end

local generate_tag_list = function(opts)
    local found = {}

    local cword = vim.fn.expand('<cword>')

    if cword == nil or cword == '' then
        return {}
    end

    ok, ts_utils = pcall(require, 'nvim-treesitter.ts_utils')
    if ok then
        local node = ts_utils.get_node_at_cursor()
        if node then
            local node_type = node:type()

            if node_type == 'identifier' or node_type == 'type_identifier' then
                local parent = node:parent()
                if parent then
                    local parent_type = parent:type()
                    if parent_type == 'qualified_identifier' then
                        -- qualified is being searched_first
                        local parent_text = vim.treesitter.query.get_node_text(parent, 0)
                        table.insert(found, find_tags(parent_text))
                    end
                end
                -- identifier from treesitter next
                local node_text = vim.treesitter.query.get_node_text(node, 0)
                table.insert(found, find_tags(node_text))
            end
        end
    end
    -- end finally cword
    table.insert(found, find_tags(cword))

    -- one level deep flatten
    found = vim.fn.flatten(found, 1)

    -- now filter out duplicates
    -- relying on order returned by vim
    local locations = {}
    local deduped = {}
    for _, v in ipairs(found) do
        -- TODO: consider line here too
        if locations[v.filename .. v.cmd] == nil then
            table.insert(deduped, v)
            locations[v.filename .. v.cmd] = true
        end
    end
    return deduped
end

local make_tags_picker = function(found_tags, opts)
    local custom_tags_finder = function(opts)
        local previewers = require('telescope.previewers')
        local conf = require('telescope.config').values
        local pickers = require('telescope.pickers')
        local make_entry = require('telescope.make_entry')
        local action_state = require "telescope.actions.state"
        local action_set = require "telescope.actions.set"
        local sorters = require "telescope.sorters"

        local finder = require 'telescope.finders'.new_dynamic {
            fn = function()
                local results = {}
                for _, v in ipairs(found_tags) do
                    table.insert(results, v.name .. '\t' .. v.filename .. '\t' .. v.cmd .. ';"\t' .. v.kind)
                end
                return results
            end,
            entry_maker = make_entry.gen_from_ctags(opts)
        }

          local tagfiles = opts.ctags_file and { opts.ctags_file } or vim.fn.tagfiles()
          for i, ctags_file in ipairs(tagfiles) do
            tagfiles[i] = vim.fn.expand(ctags_file, true)
          end
          opts.entry_maker = vim.F.if_nil(opts.entry_maker, make_entry.gen_from_ctags(opts))

          pickers.new(opts, {
            prompt_title = "Tags",
            finder = finder,
            previewer = previewers.ctags.new(opts),
            sorter = conf.generic_sorter(opts),
            attach_mappings = function()
              action_set.select:enhance {
                post = function()
                  local selection = action_state.get_selected_entry()
                  if not selection then
                    return
                  end

                  if selection.scode then
                    -- un-escape / then escape required
                    -- special chars for vim.fn.search()
                    -- ] ~ *
                    local scode = selection.scode:gsub([[\/]], "/"):gsub("[%]~*]", function(x)
                      return "\\" .. x
                    end)

                    vim.cmd "norm! gg"
                    vim.fn.search(scode)
                    vim.cmd "norm! zz"
                  else
                    vim.api.nvim_win_set_cursor(0, { selection.lnum, 0 })
                  end
                end,
              }
              return true
            end,
          }):find()

    end

    local picker_opts = {}
    picker_opts['bufnr'] = 0

    custom_tags_finder(picker_opts)
end

local navigate_to_tag = function(selection)
    local scode = selection.cmd:gsub([[\/]], "/"):gsub("[%]~*]", function(x)
       return "\\" .. x
    end)

    vim.cmd('e ' .. ' +/' .. vim.fn.escape(scode:sub(2, -2), '\\ ') .. ' ' .. vim.fn.escape(selection.filename, '\\ '))
end

local M = {}

M.jump = function(opts)
    local found_tags = generate_tag_list(oprs)
    if #found_tags == 0 then
        return
    end
    navigate_to_tag(found_tags[1])
end

M.select = function(opts)
    local found_tags = generate_tag_list(opts)
    make_tags_picker(found_tags, opts)
end

M.jump_or_select = function(opts)
    local found_tags = generate_tag_list(opts)
    if #found_tags == 1 then
        navigate_to_tag(found_tags[1])
    elseif #found_tags == 0 then
        vim.notify("No tags found", "normal", {title = "teletags"})
    else
        make_tags_picker(found_tags, opts)
    end
end

local current_popup = {
    win_id = nil,
    win_id_title = nil,
    found_tags = {},
    pos = 1
}

local function popup_alive()
    if current_popup.win_id then
        return vim.api.nvim_win_is_valid(current_popup.win_id)
    end
    return false
end

local function populate_preview()
    if popup_alive() then
        local bufnr = vim.fn.winbufnr(current_popup.win_id)
        local current = current_popup.found_tags[current_popup.pos]
        local fname = current.filename
        local match = string.sub(current.cmd, 2, -2):gsub("[%]~*]", function(x) return '\\' .. x end)
        cmd = 'grep -n "' .. match .. '" "' .. fname .. '" | cut -d : -f 1'
        -- print('Running grep', cmd)

        local grepped_pos = vim.fn.systemlist(cmd)
        -- print('Found', vim.inspect(grepped_pos))
        if #grepped_pos == 0 then
            return
        end
        local pos = tonumber(grepped_pos[1])
        local content = vim.fn.systemlist('head -n ' .. (pos+5) .. " " .. fname .. " | tail -n 8")
        local maxlen = 0
        for i, l in ipairs(content) do
            if #l > maxlen then
                maxlen = #l
            end
        end

        vim.api.nvim_win_set_config(current_popup.win_id, {width = maxlen + 5, height=8})
        vim.api.nvim_win_set_config(current_popup.win_id_title, {width = maxlen + 5})
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, content)
        local short_name = vim.fn.fnamemodify(fname, ':t')
        local title = "[" .. current_popup.pos .. "/" .. (#current_popup.found_tags) .. "] " .. short_name
        bufnr = vim.fn.winbufnr(current_popup.win_id_title)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, {title})
    end
end

local function generate_preview_window(found_tags)
    local ok, pp = pcall(require, 'plenary.popup')
    if ok then
        local popup_opts = { enter=false, time=20000, line="cursor-10", col="cursor+5", height=8}
        local title_opts = { enter=false, time=20000, line="cursor-11", col="cursor+5", height=1, highlight="Title"}
        local content = {""}
        local ft = vim.bo.filetype
        local result = pp.create(content, popup_opts)
        current_popup.win_id = result
        current_popup.win_id_title = pp.create(content, title_opts)
        local bufnr = vim.fn.winbufnr(current_popup.win_id)
        vim.api.nvim_buf_set_option(bufnr, "filetype", ft)
        vim.cmd("autocmd CursorMoved * ++once ++nested :lua require('teletags').close_tag_preview()")
        populate_preview()
        -- todo setup keymaps
    else
        return
    end
end

M.close_tag_preview = function()
    if popup_alive() then
        require('plenary.window').try_close(current_popup.win_id, true)
        require('plenary.window').try_close(current_popup.win_id_title, true)
        current_popup.win_id = nil
    end
end

M.toggle_tag_preview = function(opts)
    if popup_alive() then
        if current_popup.pos >= #(current_popup.found_tags) then
            M.close_tag_preview()
        else
            current_popup.pos = current_popup.pos + 1
            populate_preview()
        end
    else
        current_popup.found_tags = generate_tag_list(opts)
        current_popup.pos = 1
        generate_preview_window(found_tags)
    end
end

return M
