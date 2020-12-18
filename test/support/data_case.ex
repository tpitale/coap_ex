defmodule CoAP.Test.Support.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case

      import ExUnitProperties
      import CoAP.Test.Support.Factory
      import StreamData
    end
  end
end
