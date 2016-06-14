module Syntax where

import Prologue
import Data.OrderedMap
import qualified Data.Text as T

-- | A node in an abstract syntax tree.
data Syntax
  a -- ^ The type of leaves in the syntax tree, typically String, but possibly some datatype representing different leaves more precisely.
  f -- ^ The type representing another level of the tree, e.g. the children of branches. Often Cofree or Fix or similar.
  =
  -- | A terminal syntax node, e.g. an identifier, or atomic literal.
  Leaf a
  -- | An ordered branch of child nodes, expected to be variadic in the grammar, e.g. a list of statements or uncurried function parameters.
  | Indexed [f]
  -- | An ordered branch of child nodes, expected to be of fixed length in the grammar, e.g. a binary operator & its operands.
  | Fixed [f]
  -- | A branch of child nodes indexed by some String identity. This is useful for identifying e.g. methods & properties in a class scope by their names. Note that comments can generally occur in these scopes as well; one strategy for dealing with this is to identify comments by their text in the source.
  | Keyed (OrderedMap T.Text f)
  -- | A function call has an identifier where f is a (Leaf a) and a list of arguments.
  | FunctionCall f [f]
  -- | A function has a list of expressions.
  | Function { id :: (Maybe f), params :: (Maybe f), expressions :: f }
  -- | An assignment has an identifier where f can be a member access, and the value is another syntax element (function call, leaf, etc.)
  | Assignment { assignmentId :: f, value :: f }
  -- | A member access contains a syntax, and another syntax that identifies a property or value in the first syntax.
  -- | e.g. in Javascript x.y represents a member access syntax.
  | MemberAccess { memberId :: f, property :: f }
  -- | A method call consisting of its target, the method name, and the parameters passed to the method.
  -- | e.g. in Javascript console.log('hello') represents a method call.
  | MethodCall { targetId :: f, methodId :: f, methodParams :: f }
  -- | The list of arguments to a method call.
  -- | TODO: It might be worth removing this and using Fixed instead.
  | Args [f]
  | If { ifCond :: f, ifExpression :: f, elseExpression :: f }
  deriving (Functor, Show, Eq, Foldable, Traversable)
