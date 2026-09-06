"""Personal app hub — app factory, shared chrome, and module registry.

Public surface:
  - `create_app`   : Flask application factory; mounts every available module
  - `MODULE_SPECS` : the wiring table (add a module by appending one dict)
"""
from .app import create_app
from .registry import MODULE_SPECS

__all__ = ["create_app", "MODULE_SPECS"]
__version__ = "0.1.0"
