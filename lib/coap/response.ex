defmodule CoAP.Response do
  @response %{
    {2, 00} => "OK",
    {4, 04} => "Not Found"
  }
end
