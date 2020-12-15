defmodule Coap.MixProject do
  use Mix.Project

  def project do
    [
      app: :coap_ex,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {CoAP, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dev
      {:dialyxir, "~> 1.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.5", only: :dev},
      {:stream_data, "~> 0.1", only: :test},
      {:ex_doc, "~> 0.23", only: :dev, runtime: false},

      # Runtime
      {:gen_state_machine, "~> 3.0"},
      {:plug, "~> 1.11"},
      {:telemetry, "~> 0.4.0"}
    ]
  end

  defp dialyzer do
    [
      plt_ignore_apps: [:credo],
      plt_add_apps: [:ex_unit, :mix],
      ignore_warnings: ".dialyzer/ignore.exs",
      plt_file: {:no_warn, ".dialyzer/cache.plt"}
    ]
  end
end
