add-auto-load-safe-path /
set history save
set verbose off
set print pretty on
set print array off
set print array-indexes on
set python print-stack full
set debuginfod enabled on

define xxx
  x /30i $pc-40
end

define stepx
  stepi
  xxx
end
