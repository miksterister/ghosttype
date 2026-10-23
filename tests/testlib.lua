local T = { pass = 0, fail = 0 }

function T.eq(got, want, label)
  if got == want then
    T.pass = T.pass + 1
  else
    T.fail = T.fail + 1
    print(string.format("FAIL %s: got %q want %q", label, tostring(got), tostring(want)))
  end
end

function T.ok(value, label)
  if value then
    T.pass = T.pass + 1
  else
    T.fail = T.fail + 1
    print("FAIL " .. label .. ": expected truthy")
  end
end

function T.finish(name)
  print(string.format("%s: %d passed, %d failed", name, T.pass, T.fail))
  os.exit(T.fail == 0 and 0 or 1)
end

return T
