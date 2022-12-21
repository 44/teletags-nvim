--[[ this module exposes the interface of lua functions:
define here the lua functions that activate the plugin ]]

-- local main = require("teletags.main")
-- local config = require("teletags.config")

------------------
local log = require('plenary.log').new({
    plugin = 'teletags',
    level = "debug",
})

local find_tags = function(tag)
    local found_tags = vim.fn.taglist('^\\C' .. tag .. '$')
    if found_tags then
        return found_tags
    else
        return {}
    end
end

local relatives_mapping = {}

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

M.setup = function(opts)
    log.debug('mapping', vim.inspect(opts))
    relatives_mapping = opts["relatives"]
end

M.select_related = function(opts)
    local current = vim.fn.fnamemodify(vim.fn.expand('%'), ':~:.')
    local resolved = {}
    for k, v in pairs(relatives_mapping) do
        local wo_placeholder = k -- k:gsub('{}', '*')
        local ptrn = vim.fn.glob2regpat(wo_placeholder)
        for i=1,9 do
            ptrn = ptrn:gsub('=' .. i, '\\([^/]*\\)')

        end
        local matched = vim.fn.matchlist(current, ptrn)
        if #matched > 0 then
            vim.notify(ptrn .. ' => ' .. matched[2] .. ' => ' .. v )
            for ik, iv in pairs(relatives_mapping) do
                for ip, vp in ipairs(matched) do
                    if ip > 1 then
                        if #vp > 0 then
                            local to_find = ik:gsub('=' .. (ip - 1), vp)
                            resolved[to_find] = iv
                        end
                    end
                end
            end
        end
    end

    log.debug("Resolved:", resolved)
    local result = {}
    for k, v in pairs(resolved) do
        log.debug('Globbing', k, vim.fn.glob2regpat(k))
        local files = vim.fn.glob(k, true, true)
        for _, f in ipairs(files) do
            result[f] = v
        end
    end
    local flat_results = {}
    for k, v in pairs(result) do
        table.insert(flat_results, k)
    end

    local previewers = require('telescope.previewers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local pickers = require('telescope.pickers')
    local make_entry = require('telescope.make_entry')
    local action_state = require "telescope.actions.state"
    local action_set = require "telescope.actions.set"
    local sorters = require "telescope.sorters"
    local opts = {}
    local maker = make_entry.gen_from_file(opts)
    local my_maker = function(line)
        log.debug("Processing line:", line)
        local cpp_file = ".cpp"
        if line:sub(-#cpp_file) == cpp_file then
            log.debug("Filtered out")
            return
        end
        return maker(line)
    end
    require"telescope.builtin".find_files( { entry_maker = my_maker} )

    -- pickers.new(opts, {
    --     prompt_title = "Relatives",
    --     finder = finders.new_on
    --     finder1 = finders.new_table {
    --         results = flat_results,
    --         entry_maker = maker,
    --         entry_maker1 = function(e)
    --             return {
    --                 ordinal = e,
    --                 display = e,
    --                 value = e,
    --             }
    --         end,
    --     },
    --     previewer = conf.file_previewer(opts),
    --     sorter = conf.generic_sorter(opts)
    -- }):find()
end

return M
