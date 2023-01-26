interface Balancer {
  function balanceOf(address owner) external view returns (uint256 balance);
}

interface Compound {
  function mint() external payable;
  function balanceOf(address owner) external view returns (uint256 balance);
  function transfer(address recipient, uint256 amount) external returns (bool);
}

interface Hevm {
  function prank(address) external;
}

contract TestRPC {
  address constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
  // BAL: https://etherscan.io/address/0xba100000625a3754423978a60c9317c58a424e3D#code
  Balancer bal = Balancer(0xba100000625a3754423978a60c9317c58a424e3D);
  // COMP: https://etherscan.io/token/0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5
  Compound comp = Compound(0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5);

  uint balance = 0;
  uint balance2 = 0;

  function foo() public {
    balance = bal.balanceOf(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
  }

  function bar() public {
    balance2 = comp.balanceOf(0xe84A061897afc2e7fF5FB7e3686717C528617487);
  }

  // block: 16198552
  function echidna_fetch_balance() public returns (bool) {
    return balance != 27099516537379438397130892;
  }

  // block: 15947726 or latest
  function echidna_fetch_balance2() public returns (bool) {
    return balance2 != 146775316216684;
  }
}
