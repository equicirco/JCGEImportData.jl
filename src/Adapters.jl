"""
Adapter stubs for external data sources.
"""
module Adapters

export EurostatAdapter
export GTAPAdapter
export load_iobundle

"""
    EurostatAdapter(source)

Placeholder for Eurostat-specific IO/SAM extraction.
"""
struct EurostatAdapter
    source::String
end

"""
    GTAPAdapter(source)

Placeholder for GTAP-specific IO/SAM extraction.
"""
struct GTAPAdapter
    source::String
end

"""
    load_iobundle(::EurostatAdapter)

Stub adapter: normalize external Eurostat data into an `IOBundle`.
"""
function load_iobundle(::EurostatAdapter)
    error("Eurostat adapter not implemented yet. Map your source tables into an IOBundle.")
end

"""
    load_iobundle(::GTAPAdapter)

Stub adapter: normalize external GTAP data into an `IOBundle`.
"""
function load_iobundle(::GTAPAdapter)
    error("GTAP adapter not implemented yet. Map your source tables into an IOBundle.")
end

end # module
