# typed: strict
# frozen_string_literal: true

module RubyLsp
  module Requests
    # ![Document symbol demo](../../document_symbol.gif)
    #
    # The [document
    # symbol](https://microsoft.github.io/language-server-protocol/specification#textDocument_documentSymbol) request
    # informs the editor of all the important symbols, such as classes, variables, and methods, defined in a file. With
    # this information, the editor can populate breadcrumbs, file outline and allow for fuzzy symbol searches.
    #
    # In VS Code, fuzzy symbol search can be accessed by opening the command palette and inserting an `@` symbol.
    #
    # # Example
    #
    # ```ruby
    # class Person # --> document symbol: class
    #   attr_reader :age # --> document symbol: field
    #
    #   def initialize
    #     @age = 0 # --> document symbol: variable
    #   end
    #
    #   def age # --> document symbol: method
    #   end
    # end
    # ```
    class DocumentSymbol < Listener
      extend T::Sig
      extend T::Generic

      ResponseType = type_member { { fixed: T::Array[Interface::DocumentSymbol] } }

      SYMBOL_KIND = T.let(
        {
          file: 1,
          module: 2,
          namespace: 3,
          package: 4,
          class: 5,
          method: 6,
          property: 7,
          field: 8,
          constructor: 9,
          enum: 10,
          interface: 11,
          function: 12,
          variable: 13,
          constant: 14,
          string: 15,
          number: 16,
          boolean: 17,
          array: 18,
          object: 19,
          key: 20,
          null: 21,
          enummember: 22,
          struct: 23,
          event: 24,
          operator: 25,
          typeparameter: 26,
        }.freeze,
        T::Hash[Symbol, Integer],
      )

      ATTR_ACCESSORS = T.let(["attr_reader", "attr_writer", "attr_accessor"].freeze, T::Array[String])

      class SymbolHierarchyRoot
        extend T::Sig

        sig { returns(T::Array[Interface::DocumentSymbol]) }
        attr_reader :children

        sig { void }
        def initialize
          @children = T.let([], T::Array[Interface::DocumentSymbol])
        end
      end

      sig { override.returns(T::Array[Interface::DocumentSymbol]) }
      attr_reader :response

      sig { params(emitter: EventEmitter, message_queue: Thread::Queue).void }
      def initialize(emitter, message_queue)
        super

        @root = T.let(SymbolHierarchyRoot.new, SymbolHierarchyRoot)
        @response = T.let(@root.children, T::Array[Interface::DocumentSymbol])
        @stack = T.let(
          [@root],
          T::Array[T.any(SymbolHierarchyRoot, Interface::DocumentSymbol)],
        )

        emitter.register(
          self,
          :on_class,
          :after_class,
          :on_call,
          :on_constant_path_write,
          :on_constant_write,
          :on_def,
          :after_def,
          :on_module,
          :after_module,
          :on_instance_variable_write,
          :on_class_variable_write,
        )
      end

      sig { params(node: YARP::ClassNode).void }
      def on_class(node)
        @stack << create_document_symbol(
          name: node.constant_path.location.slice,
          kind: :class,
          range_node: node,
          selection_range_node: node.constant_path,
        )
      end

      sig { params(node: YARP::ClassNode).void }
      def after_class(node)
        @stack.pop
      end

      sig { params(node: YARP::CallNode).void }
      def on_call(node)
        return unless ATTR_ACCESSORS.include?(node.name) && node.receiver.nil?

        arguments = node.arguments
        return unless arguments

        arguments.arguments.each do |argument|
          next unless argument.is_a?(YARP::SymbolNode)

          create_document_symbol(
            name: argument.value,
            kind: :field,
            range_node: argument,
            selection_range_node: argument,
          )
        end
      end

      sig { params(node: YARP::ConstantPathWriteNode).void }
      def on_constant_path_write(node)
        create_document_symbol(
          name: node.target.location.slice,
          kind: :constant,
          range_node: node,
          selection_range_node: node.target,
        )
      end

      sig { params(node: YARP::ConstantWriteNode).void }
      def on_constant_write(node)
        create_document_symbol(
          name: node.name,
          kind: :constant,
          range_node: node,
          selection_range_node: node.name_loc,
        )
      end

      sig { params(node: YARP::DefNode).void }
      def on_def(node)
        receiver = node.receiver

        if receiver.is_a?(YARP::SelfNode)
          name = "self.#{node.name}"
          kind = :method
        else
          name = node.name
          kind = name == "initialize" ? :constructor : :method
        end

        symbol = create_document_symbol(
          name: name,
          kind: kind,
          range_node: node,
          selection_range_node: node.name_loc,
        )

        @stack << symbol
      end

      sig { params(node: YARP::DefNode).void }
      def after_def(node)
        @stack.pop
      end

      sig { params(node: YARP::ModuleNode).void }
      def on_module(node)
        @stack << create_document_symbol(
          name: node.constant_path.location.slice,
          kind: :module,
          range_node: node,
          selection_range_node: node.constant_path,
        )
      end

      sig { params(node: YARP::ModuleNode).void }
      def after_module(node)
        @stack.pop
      end

      sig { params(node: YARP::InstanceVariableWriteNode).void }
      def on_instance_variable_write(node)
        create_document_symbol(
          name: node.name.to_s,
          kind: :variable,
          range_node: node,
          selection_range_node: node.name_loc,
        )
      end

      sig { params(node: YARP::ClassVariableWriteNode).void }
      def on_class_variable_write(node)
        create_document_symbol(
          name: node.name.to_s,
          kind: :variable,
          range_node: node,
          selection_range_node: node.name_loc,
        )
      end

      private

      sig do
        params(
          name: String,
          kind: Symbol,
          range_node: YARP::Node,
          selection_range_node: T.any(YARP::Node, YARP::Location),
        ).returns(Interface::DocumentSymbol)
      end
      def create_document_symbol(name:, kind:, range_node:, selection_range_node:)
        selection_range = if selection_range_node.is_a?(YARP::Node)
          range_from_syntax_tree_node(selection_range_node)
        else
          range_from_location(selection_range_node)
        end

        symbol = Interface::DocumentSymbol.new(
          name: name,
          kind: SYMBOL_KIND[kind],
          range: range_from_syntax_tree_node(range_node),
          selection_range: selection_range,
          children: [],
        )

        T.must(@stack.last).children << symbol

        symbol
      end
    end
  end
end
