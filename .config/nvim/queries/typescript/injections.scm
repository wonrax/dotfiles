([
  (string)
  (template_string)
 ] @injection.content
 (#match? @injection.content "(SELECT|select|INSERT|insert|UPDATE|update|DELETE|delete|CREATE|create).+(FROM|from|INTO|into|VALUES|values|SET|set|TABLE|table).*(WHERE|where|GROUP BY|group by)?")
(#set! injection.language "sql")
(#set! injection.include-children))
