# frozen_string_literal: true

# ==============================================================================
# Memory Module (DEPRECATED - Jan 2026)
# ==============================================================================
# Old Memory MCP CLI commands have been removed. Memory is now handled by:
#   - Official Memory MCP (@modelcontextprotocol/server-memory) for durable facts
#   - session_learnings.jsonl for automated session capture
#
# This stub module exists to prevent errors from `include SaneMasterModules::Memory`
# in SaneMaster.rb. All methods show deprecation notices.
# ==============================================================================

module SaneMasterModules
  module Memory
    DEPRECATION_NOTICE = <<~MSG

      ================================================================
      DEPRECATED: Memory CLI commands removed (Jan 2026)

      Memory is now handled by:
        - Official Memory MCP for durable facts (knowledge-graph.jsonl)
        - session_learnings.jsonl for automated session capture

      These CLI commands no longer function.
      ================================================================

    MSG

    def show_memory_context_summary
      # No-op: Memory MCP removed
    end

    def show_memory_context(_args)
      warn DEPRECATION_NOTICE
    end

    def record_memory_entity(_args)
      warn DEPRECATION_NOTICE
    end

    def prune_memory_entities(_args)
      warn DEPRECATION_NOTICE
    end

    def memory_health(_args = [])
      warn DEPRECATION_NOTICE
    end

    def memory_compact(_args)
      warn DEPRECATION_NOTICE
    end

    def check_memory_size_warning
      # No-op: Memory MCP removed
    end

    def memory_cleanup(_args)
      warn DEPRECATION_NOTICE
    end

    def auto_memory_check(_args = [])
      # No-op: Memory MCP removed
    end

    def memory_archive_stats(_args = [])
      warn DEPRECATION_NOTICE
    end

    def auto_record_fix(_name, _observations)
      # No-op: Memory MCP removed
    end

    def auto_record_architecture(_name, _observations)
      # No-op: Memory MCP removed
    end

    def auto_record_concurrency(_name, _observations)
      # No-op: Memory MCP removed
    end

    def auto_record(_entity_type, _name, _observations)
      # No-op: Memory MCP removed
    end

    def suggest_memory_record
      # No-op: Memory MCP removed
    end

    private

    # Stub private methods to prevent NoMethodError
    def show_entity_group(*); end
    def find_stale_entities(*); []; end
    def estimate_tokens(*); 0; end
    def find_verbose_entities(*); []; end
    def find_duplicate_candidates(*); []; end
  end
end
